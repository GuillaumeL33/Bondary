// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BondaryWhitelist} from "./BondaryWhitelist.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";

/**
 * @title BondVault
 * @notice Vault ERC-4626 représentant une obligation tokenisée (security token).
 *
 * Cycle de vie :
 *   SUBSCRIPTION → souscription ouverte aux investisseurs KYC
 *   ACTIVE       → prêt activé, fonds tirés par l'emprunteur, intérêts courus
 *   CLOSED       → prêt remboursé, investisseurs peuvent racheter leurs parts
 *   FAILED       → soft cap non atteint, remboursement intégral possible
 *   DEFAULTED    → défaut de l'emprunteur ; l'admin résout via resolveDefault()
 *
 * Sécurité :
 *   - Security token : les transferts sont restreints aux adresses KYC validées
 *   - UUPS upgradeable : l'implémentation peut être mise à jour par le DEFAULT_ADMIN_ROLE
 *   - ReentrancyGuard sur toutes les fonctions à transfert de fonds
 */
contract BondVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    //  Constantes
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    uint256 public constant YEAR_IN_SECONDS = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────────────────

    enum State {
        SUBSCRIPTION, // 0
        ACTIVE,       // 1
        CLOSED,       // 2
        FAILED,       // 3
        DEFAULTED     // 4
    }

    struct VaultParams {
        uint256 interestRateBps;        // Taux annuel investisseurs (ex: 800 = 8.00 %)
        uint256 platformInterestFeeBps; // % des intérêts prélevés par Bondary (ex: 1000 = 10 %)
        uint256 setupFeeBps;            // Frais de dossier en BPS du montant levé (ex: 100 = 1 %)
        uint256 softCap;                // Montant minimum pour valider la levée (en wei asset)
        uint256 hardCap;                // Montant maximum de la levée (en wei asset)
        uint256 minDeposit;             // Dépôt minimum par investisseur (50 € en wei)
        uint256 subscriptionEnd;        // Timestamp de fin de souscription
        uint256 loanDuration;           // Durée du prêt en secondes
        uint256 gracePeriod;            // Délai de grâce après maturité avant défaut
        address borrower;               // Adresse de l'emprunteur (SPV)
        address whitelistAddr;          // BondaryWhitelist
        address feeCollectorAddr;       // BondaryFeeCollector
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public interestRateBps;
    uint256 public platformInterestFeeBps;
    uint256 public setupFeeBps;
    uint256 public softCap;
    uint256 public hardCap;
    uint256 public minDeposit;
    uint256 public subscriptionEnd;
    uint256 public loanDuration;
    uint256 public gracePeriod;
    address public borrower;
    BondaryWhitelist  public whitelistContract;
    BondaryFeeCollector public feeCollector;

    State   public state;
    uint256 public totalBorrowed;
    uint256 public accruedInterestSnapshot; // intérêts cristallisés au dernier snapshot
    uint256 public lastInterestUpdate;
    uint256 public loanStart;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event StateChanged(State indexed oldState, State indexed newState);
    event LoanActivated(uint256 totalRaised, uint256 setupFee);
    event LoanDrawn(address indexed borrower, uint256 amount, uint256 newTotalBorrowed);
    event LoanRepaid(address indexed borrower, uint256 principal, uint256 grossInterest, uint256 platformFee);
    event DefaultDeclared();
    event DefaultResolved(uint256 recoveredAmount);

    // ─────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyState(State _state) {
        require(state == _state, "BondVault: invalid state");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor / Initializer
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        VaultParams calldata params,
        address admin
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_asset);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BORROWER_ROLE, params.borrower);

        require(params.softCap <= params.hardCap,           "BondVault: softCap > hardCap");
        require(params.subscriptionEnd > block.timestamp,   "BondVault: subscriptionEnd in past");
        require(params.loanDuration > 0,                    "BondVault: zero duration");
        require(params.interestRateBps > 0,                 "BondVault: zero rate");
        require(params.platformInterestFeeBps < BPS_DENOMINATOR, "BondVault: fee >= 100%");

        interestRateBps        = params.interestRateBps;
        platformInterestFeeBps = params.platformInterestFeeBps;
        setupFeeBps            = params.setupFeeBps;
        softCap                = params.softCap;
        hardCap                = params.hardCap;
        minDeposit             = params.minDeposit;
        subscriptionEnd        = params.subscriptionEnd;
        loanDuration           = params.loanDuration;
        gracePeriod            = params.gracePeriod;
        borrower               = params.borrower;
        whitelistContract      = BondaryWhitelist(params.whitelistAddr);
        feeCollector           = BondaryFeeCollector(params.feeCollectorAddr);

        state = State.SUBSCRIPTION;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ERC-4626 overrides : calcul de la valeur liquidative (NAV)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Retourne la valeur totale des actifs du vault.
     *
     * En phase ACTIVE, la valeur comprend :
     *   cash restant dans le vault
     *   + principal prêté
     *   + intérêts courus nets (déduit la part plateforme)
     *
     * Le prix des parts augmente en temps réel au fil des intérêts.
     */
    function totalAssets() public view override returns (uint256) {
        if (state != State.ACTIVE) {
            // SUBSCRIPTION, FAILED  → juste le cash (intérêts = 0)
            // CLOSED                → cash après remboursement complet
            // DEFAULTED             → cash restant dans le vault (peut être 0)
            return super.totalAssets();
        }

        uint256 cashInVault   = super.totalAssets();
        uint256 grossInterest = accruedInterestSnapshot + _calculatePendingInterest();
        uint256 platformFee   = (grossInterest * platformInterestFeeBps) / BPS_DENOMINATOR;
        uint256 netInterest   = grossInterest - platformFee;

        return cashInVault + totalBorrowed + netInterest;
    }

    /**
     * @dev Les parts ont le même nombre de décimales que l'asset sous-jacent
     *      (6 pour USDC/EURC) — 100 € déposés = 100 parts affichées.
     */
    function decimals()
        public
        view
        override(ERC4626Upgradeable)
        returns (uint8)
    {
        return IERC20Metadata(asset()).decimals();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ERC-4626 : dépôts (uniquement en SUBSCRIPTION)
    // ─────────────────────────────────────────────────────────────────────────

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _requireSubscriptionOpen(assets, receiver);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewMint(shares);
        _requireSubscriptionOpen(assets, receiver);
        return super.mint(shares, receiver);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (state != State.SUBSCRIPTION) return 0;
        if (block.timestamp >= subscriptionEnd) return 0;
        if (!whitelistContract.isWhitelisted(receiver)) return 0;
        uint256 current = super.totalAssets();
        if (current >= hardCap) return 0;
        return hardCap - current;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == 0 ? 0 : previewDeposit(maxAssets);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ERC-4626 : rachats (uniquement en CLOSED ou FAILED)
    // ─────────────────────────────────────────────────────────────────────────

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        require(state == State.CLOSED || state == State.FAILED, "BondVault: not redeemable");
        require(whitelistContract.isWhitelisted(receiver), "BondVault: receiver not KYC");
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        require(state == State.CLOSED || state == State.FAILED, "BondVault: not redeemable");
        require(whitelistContract.isWhitelisted(receiver), "BondVault: receiver not KYC");
        return super.redeem(shares, receiver, owner_);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (state != State.CLOSED && state != State.FAILED) return 0;
        return super.maxWithdraw(owner_);
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (state != State.CLOSED && state != State.FAILED) return 0;
        return super.maxRedeem(owner_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Security token : transferts restreints aux adresses KYC
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Surcharge ERC-20 : mint (from=0) et burn (to=0) sont libres,
     *      mais tout transfert entre wallets exige que le destinataire soit KYC.
     *      Le marketplace (contrat officiel whitelisté) doit être dans le whitelist.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(whitelistContract.isWhitelisted(to), "BondVault: recipient not KYC");
        }
        super._update(from, to, value);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Lifecycle : Admin
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Active le prêt après la souscription.
     *         Prélève les frais de dossier, démarre l'horloge des intérêts.
     *         Peut être appelé dès que le hardCap est atteint ou après subscriptionEnd.
     */
    function activateLoan() external onlyRole(ADMIN_ROLE) onlyState(State.SUBSCRIPTION) {
        uint256 raised = super.totalAssets();
        require(
            block.timestamp >= subscriptionEnd || raised >= hardCap,
            "BondVault: subscription still open"
        );
        require(raised >= softCap, "BondVault: soft cap not reached");

        // Frais de dossier prélevés sur le montant levé, envoyés au FeeCollector
        uint256 setupFee = (raised * setupFeeBps) / BPS_DENOMINATOR;
        if (setupFee > 0) {
            IERC20(asset()).safeTransfer(address(feeCollector), setupFee);
            feeCollector.notifyFeeReceived(asset(), setupFee, BondaryFeeCollector.FeeType.SETUP);
        }

        loanStart           = block.timestamp;
        lastInterestUpdate  = block.timestamp;

        _changeState(State.ACTIVE);
        emit LoanActivated(raised, setupFee);
    }

    /**
     * @notice Déclare la souscription en échec (soft cap non atteint).
     *         Les investisseurs peuvent ensuite racheter leur dépôt intégral.
     */
    function failSubscription() external onlyRole(ADMIN_ROLE) onlyState(State.SUBSCRIPTION) {
        require(block.timestamp >= subscriptionEnd, "BondVault: subscription still open");
        require(super.totalAssets() < softCap,      "BondVault: soft cap reached");
        _changeState(State.FAILED);
    }

    /**
     * @notice Déclare un défaut après la maturité + période de grâce.
     *         Fige les intérêts. L'admin résout ensuite via resolveDefault().
     */
    function declareDefault() external onlyRole(ADMIN_ROLE) onlyState(State.ACTIVE) {
        require(
            block.timestamp > loanStart + loanDuration + gracePeriod,
            "BondVault: grace period not elapsed"
        );
        _snapInterest(); // fige les intérêts à la date du défaut
        _changeState(State.DEFAULTED);
        emit DefaultDeclared();
    }

    /**
     * @notice Résout le défaut : l'admin injecte les fonds récupérés (légal off-chain)
     *         et passe le vault en CLOSED pour permettre le rachat proportionnel.
     */
    function resolveDefault(uint256 recoveredAmount)
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.DEFAULTED)
    {
        if (recoveredAmount > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), recoveredAmount);
        }
        totalBorrowed          = 0;
        accruedInterestSnapshot = 0;
        _changeState(State.CLOSED);
        emit DefaultResolved(recoveredAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Lifecycle : Borrower
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice L'emprunteur tire tout ou partie des fonds levés.
     *         Les intérêts sont cristallisés avant chaque tirage pour que
     *         le nouveau montant emprunté parte d'une base propre.
     */
    function drawLoan(uint256 amount)
        external
        onlyRole(BORROWER_ROLE)
        nonReentrant
        onlyState(State.ACTIVE)
        whenNotPaused
    {
        require(amount > 0, "BondVault: zero amount");
        uint256 available = IERC20(asset()).balanceOf(address(this));
        require(amount <= available, "BondVault: insufficient cash");

        _snapInterest();
        totalBorrowed += amount;

        IERC20(asset()).safeTransfer(borrower, amount);
        emit LoanDrawn(borrower, amount, totalBorrowed);
    }

    /**
     * @notice Remboursement in fine : l'emprunteur rembourse principal + intérêts bruts.
     *         La part plateforme est envoyée au FeeCollector, le reste revient aux investisseurs.
     *         Passage automatique en CLOSED.
     */
    function repayLoan()
        external
        onlyRole(BORROWER_ROLE)
        nonReentrant
        onlyState(State.ACTIVE)
    {
        _snapInterest();

        uint256 grossInterest = accruedInterestSnapshot;
        uint256 platformFee   = (grossInterest * platformInterestFeeBps) / BPS_DENOMINATOR;
        uint256 netInterest   = grossInterest - platformFee;
        uint256 principal     = totalBorrowed;

        // Transfert principal + intérêts nets → vault (revient aux investisseurs)
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), principal + netInterest);

        // Transfert frais plateforme → FeeCollector
        if (platformFee > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(feeCollector), platformFee);
            feeCollector.notifyFeeReceived(asset(), platformFee, BondaryFeeCollector.FeeType.INTEREST);
        }

        emit LoanRepaid(msg.sender, principal, grossInterest, platformFee);

        totalBorrowed           = 0;
        accruedInterestSnapshot = 0;
        _changeState(State.CLOSED);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Intérêts
    // ─────────────────────────────────────────────────────────────────────────

    function _calculatePendingInterest() internal view returns (uint256) {
        if (totalBorrowed == 0 || lastInterestUpdate == 0) return 0;
        uint256 elapsed = block.timestamp - lastInterestUpdate;
        return (totalBorrowed * interestRateBps * elapsed) / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
    }

    function _snapInterest() internal {
        accruedInterestSnapshot += _calculatePendingInterest();
        lastInterestUpdate       = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views pratiques
    // ─────────────────────────────────────────────────────────────────────────

    function loanMaturity() external view returns (uint256) {
        return loanStart == 0 ? 0 : loanStart + loanDuration;
    }

    function currentDebt() external view returns (uint256) {
        return totalBorrowed + accruedInterestSnapshot + _calculatePendingInterest();
    }

    function isLoanMatured() external view returns (bool) {
        return loanStart > 0 && block.timestamp >= loanStart + loanDuration;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Sécurité
    // ─────────────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    /// @dev Seul le DEFAULT_ADMIN_ROLE (Gnosis Safe) peut upgrader l'implémentation.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _requireSubscriptionOpen(uint256 assets, address receiver) internal view {
        require(state == State.SUBSCRIPTION,                      "BondVault: not in subscription");
        require(block.timestamp < subscriptionEnd,                "BondVault: subscription ended");
        require(whitelistContract.isWhitelisted(receiver),        "BondVault: not KYC");
        require(assets >= minDeposit,                             "BondVault: below min deposit");
        require(super.totalAssets() + assets <= hardCap,          "BondVault: hard cap exceeded");
    }

    function _changeState(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
    }
}
