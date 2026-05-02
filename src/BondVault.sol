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
 * Sécurité (audit v2) :
 *   - setupFeeBps plafonné à < 100 % pour prévenir tout rug-pull
 *   - _totalDeposited traque les dépôts indépendamment du balanceOf :
 *     les donations ERC20 directes ne peuvent plus forcer une activation prématurée
 *   - Upgrade UUPS : délai obligatoire de 48 h entre proposeUpgrade() et
 *     l'exécution effective dans _authorizeUpgrade()
 *   - emergencyFailSubscription() : sortie permissionless pour les investisseurs
 *     si l'admin est indisponible après subscriptionEnd + 7 jours
 *   - resolveDefault(0) émet DefaultResolvedZeroRecovery pour alerter les
 *     systèmes off-chain que les investisseurs ne récupèrent rien
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

    uint256 public constant YEAR_IN_SECONDS         = 365 days;
    uint256 public constant BPS_DENOMINATOR         = 10_000;
    uint256 public constant UPGRADE_TIMELOCK        = 48 hours;
    uint256 public constant SUBSCRIPTION_ESCAPE_DELAY = 7 days;

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
        uint256 minDeposit;             // Dépôt minimum par investisseur (ex: 50 € en wei)
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
    BondaryWhitelist    public whitelistContract;
    BondaryFeeCollector public feeCollector;

    State   public state;
    uint256 public totalBorrowed;
    uint256 public accruedInterestSnapshot;
    uint256 public lastInterestUpdate;
    uint256 public loanStart;

    // Tracks actual investor deposits independently of balanceOf().
    // Prevents ERC20 donations from manipulating lifecycle cap checks.
    uint256 private _totalDeposited;

    // Upgrade timelock state
    address public pendingUpgradeImpl;
    uint256 public pendingUpgradeTimestamp;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event StateChanged(State indexed oldState, State indexed newState);
    event LoanActivated(uint256 totalRaised, uint256 setupFee);
    event LoanDrawn(address indexed borrower, uint256 amount, uint256 newTotalBorrowed);
    event LoanRepaid(address indexed borrower, uint256 principal, uint256 grossInterest, uint256 platformFee);
    event DefaultDeclared();
    event DefaultResolved(uint256 recoveredAmount);
    event DefaultResolvedZeroRecovery();
    event UpgradeProposed(address indexed newImpl, uint256 executeAfter);
    event UpgradeCancelled(address indexed cancelledImpl);

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

        require(params.softCap <= params.hardCap,                        "BondVault: softCap > hardCap");
        require(params.subscriptionEnd > block.timestamp,                "BondVault: subscriptionEnd in past");
        require(params.loanDuration > 0,                                 "BondVault: zero duration");
        require(params.interestRateBps > 0,                              "BondVault: zero rate");
        require(params.platformInterestFeeBps < BPS_DENOMINATOR,         "BondVault: platform fee >= 100%");
        require(params.setupFeeBps < BPS_DENOMINATOR,                    "BondVault: setup fee >= 100%");
        require(params.minDeposit > 0,                                   "BondVault: zero minDeposit");
        require(params.whitelistAddr != address(0),                      "BondVault: zero whitelist");
        require(params.feeCollectorAddr != address(0),                   "BondVault: zero feeCollector");

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
     * En phase ACTIVE :
     *   cash restant + principal prêté + intérêts nets courus
     */
    function totalAssets() public view override returns (uint256) {
        if (state != State.ACTIVE) {
            return super.totalAssets();
        }

        uint256 cashInVault   = super.totalAssets();
        uint256 grossInterest = accruedInterestSnapshot + _calculatePendingInterest();
        uint256 platformFee   = (grossInterest * platformInterestFeeBps) / BPS_DENOMINATOR;
        uint256 netInterest   = grossInterest - platformFee;

        return cashInVault + totalBorrowed + netInterest;
    }

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

    /**
     * @dev Override _deposit to track investor deposits independently of balanceOf().
     *      This prevents ERC20 donations from affecting hardCap / softCap logic.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        _totalDeposited += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (state != State.SUBSCRIPTION) return 0;
        if (block.timestamp >= subscriptionEnd) return 0;
        if (!whitelistContract.isWhitelisted(receiver)) return 0;
        if (_totalDeposited >= hardCap) return 0;
        return hardCap - _totalDeposited;
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
     *         Utilise _totalDeposited (donation-resistant) pour les vérifications.
     */
    function activateLoan() external onlyRole(ADMIN_ROLE) onlyState(State.SUBSCRIPTION) {
        require(
            block.timestamp >= subscriptionEnd || _totalDeposited >= hardCap,
            "BondVault: subscription still open"
        );
        require(_totalDeposited >= softCap, "BondVault: soft cap not reached");

        uint256 raised   = _totalDeposited;
        uint256 setupFee = (raised * setupFeeBps) / BPS_DENOMINATOR;
        if (setupFee > 0) {
            IERC20(asset()).safeTransfer(address(feeCollector), setupFee);
            feeCollector.notifyFeeReceived(asset(), setupFee, BondaryFeeCollector.FeeType.SETUP);
        }

        loanStart          = block.timestamp;
        lastInterestUpdate = block.timestamp;

        _changeState(State.ACTIVE);
        emit LoanActivated(raised, setupFee);
    }

    /**
     * @notice Déclare la souscription en échec (soft cap non atteint).
     */
    function failSubscription() external onlyRole(ADMIN_ROLE) onlyState(State.SUBSCRIPTION) {
        require(block.timestamp >= subscriptionEnd, "BondVault: subscription still open");
        require(_totalDeposited < softCap,           "BondVault: soft cap reached");
        _changeState(State.FAILED);
    }

    /**
     * @notice Sortie permissionless : tout appelant peut déclarer l'échec de la
     *         souscription si l'admin n'a pas agi 7 jours après subscriptionEnd
     *         et que le softCap n'est pas atteint.
     *         Protège les investisseurs contre l'indisponibilité de l'admin.
     */
    function emergencyFailSubscription() external onlyState(State.SUBSCRIPTION) {
        require(
            block.timestamp >= subscriptionEnd + SUBSCRIPTION_ESCAPE_DELAY,
            "BondVault: escape delay not elapsed"
        );
        require(_totalDeposited < softCap, "BondVault: soft cap reached");
        _changeState(State.FAILED);
    }

    /**
     * @notice Déclare un défaut après la maturité + période de grâce.
     */
    function declareDefault() external onlyRole(ADMIN_ROLE) onlyState(State.ACTIVE) {
        require(
            block.timestamp > loanStart + loanDuration + gracePeriod,
            "BondVault: grace period not elapsed"
        );
        _snapInterest();
        _changeState(State.DEFAULTED);
        emit DefaultDeclared();
    }

    /**
     * @notice Résout le défaut en injectant les fonds récupérés.
     *         Si recoveredAmount == 0, émet DefaultResolvedZeroRecovery pour
     *         alerter les systèmes off-chain que les investisseurs ne récupèrent rien.
     */
    function resolveDefault(uint256 recoveredAmount)
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.DEFAULTED)
    {
        if (recoveredAmount > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), recoveredAmount);
        } else {
            emit DefaultResolvedZeroRecovery();
        }
        totalBorrowed           = 0;
        accruedInterestSnapshot = 0;
        _changeState(State.CLOSED);
        emit DefaultResolved(recoveredAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Lifecycle : Borrower
    // ─────────────────────────────────────────────────────────────────────────

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

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), principal + netInterest);

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
    //  Views
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

    function totalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Sécurité / Pause
    // ─────────────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────────
    //  Upgrade UUPS avec timelock 48h
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Propose une nouvelle implémentation. L'upgrade ne peut être exécuté
     *         qu'après UPGRADE_TIMELOCK (48 h), laissant le temps aux investisseurs
     *         et aux systèmes de monitoring de détecter une mise à jour malveillante.
     */
    function proposeUpgrade(address newImpl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImpl != address(0), "BondVault: zero impl");
        pendingUpgradeImpl      = newImpl;
        pendingUpgradeTimestamp = block.timestamp + UPGRADE_TIMELOCK;
        emit UpgradeProposed(newImpl, pendingUpgradeTimestamp);
    }

    /**
     * @notice Annule une proposition d'upgrade en cours.
     */
    function cancelUpgrade() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit UpgradeCancelled(pendingUpgradeImpl);
        pendingUpgradeImpl      = address(0);
        pendingUpgradeTimestamp = 0;
    }

    /**
     * @dev Seul un upgrade correctement proposé ET dont le délai est écoulé peut être exécuté.
     */
    function _authorizeUpgrade(address newImpl) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImpl == pendingUpgradeImpl,            "BondVault: upgrade not proposed");
        require(block.timestamp >= pendingUpgradeTimestamp, "BondVault: timelock not elapsed");
        pendingUpgradeImpl      = address(0);
        pendingUpgradeTimestamp = 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _requireSubscriptionOpen(uint256 assets, address receiver) internal view {
        require(state == State.SUBSCRIPTION,                             "BondVault: not in subscription");
        require(block.timestamp < subscriptionEnd,                       "BondVault: subscription ended");
        require(whitelistContract.isWhitelisted(receiver),               "BondVault: not KYC");
        require(assets >= minDeposit,                                    "BondVault: below min deposit");
        require(_totalDeposited + assets <= hardCap,                     "BondVault: hard cap exceeded");
    }

    function _changeState(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
    }
}
