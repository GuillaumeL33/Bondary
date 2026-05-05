// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";
import {IERC3643, ICompliance, IIdentity, IIdentityRegistry} from "./interfaces/IERC3643.sol";

/**
 * @title CorporateBond
 * @notice Token ERC-20 représentant une obligation corporate tokenisée.
 *
 *  Modèle économique :
 *    1 bond token = 1 unité de nominal (ex: 1 USDC de dette).
 *    Les tokens représentent une créance, pas une part de vault.
 *    Décimales = 0 → chaque token est une obligation entière.
 *
 *  Cycle de vie :
 *    SUBSCRIPTION → souscription ouverte (investisseurs déposent les fonds)
 *    ACTIVE       → émission validée, tokens mintés, fonds versés à l'émetteur
 *    MATURED      → maturité atteinte, remboursement du principal possible
 *    CLOSED       → tous les tokens rachetés, obligation clôturée
 *    FAILED       → soft cap non atteint, remboursement intégral des souscripteurs
 *
 *  Deux modes de paiement configurables à l'émission :
 *    COUPON : intérêts versés périodiquement (trimestre/semestre/annuel)
 *             + principal remboursé à maturité
 *    BULLET : aucun paiement intermédiaire, principal + intérêts totaux à maturité
 *
 *  Security token (MiFID II) :
 *    Tous les transferts vérifient ComplianceManager.isVerified() pour from ET to.
 *    Seules les adresses KYC validées et non blacklistées peuvent détenir le token.
 *
 *  Coupon accrual (mode COUPON) :
 *    Pattern "dividend per token" : les coupons s'accumulent dans un compteur global
 *    totalCouponPerToken. Chaque transfert déclenche l'accrual pour les deux parties.
 *    Les investisseurs réclament leurs coupons accumulés via claimCoupons().
 */
contract CorporateBond is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IERC3643
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    //  Constantes
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant AGENT_ROLE  = keccak256("AGENT_ROLE");

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant YEAR_IN_SECONDS  = 365 days;
    uint256 public constant MAX_BATCH_SIZE   = 200;    // DoS protection on batch calls
    uint256 public constant PRECISION        = 1e18;
    string  public constant TOKEN_VERSION    = "1.0.0-erc3643";

    // ─────────────────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────────────────

    enum State { SUBSCRIPTION, ACTIVE, MATURED, CLOSED, FAILED }

    enum PaymentMode { COUPON, BULLET }

    struct BondTerms {
        uint256 faceValue;           // USDC_wei par bond entier (ex: 1e6 = 1 USDC)
        uint256 totalIssuance;       // nombre total de bonds à émettre (entiers)
        uint256 softCap;             // minimum de bonds pour valider la levée
        uint256 issuancePrice;       // USDC_wei par bond à la souscription (peut ≠ faceValue)
        uint256 minInvestment;       // montant minimum en USDC_wei (ex: 50e6 = 50 USDC)
        uint256 couponRate;          // taux annuel en BPS (ex: 800 = 8.00 %)
        uint256 maturityDate;        // timestamp d'échéance
        uint256 couponFrequency;     // intervalle en secondes (ex: 90 days = trimestriel)
        PaymentMode paymentMode;     // COUPON ou BULLET
        bool earlyBuybackEnabled;    // l'émetteur peut-il racheter avant maturité ?
        uint256 subscriptionEnd;     // timestamp de fin de souscription
        address paymentToken;        // USDC ou EURC
        address issuer;              // adresse de l'émetteur (reçoit les fonds levés)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────────

    BondTerms public terms;
    State     public state;

    // Souscription
    mapping(address => uint256) public subscriptions;      // bonds souscrits par adresse
    mapping(address => uint256) public paymentDeposited;   // USDC_wei déposés par adresse
    mapping(address => bool)    public allocationClaimed;  // token déjà réclamés ?
    uint256 public totalSubscribed;                        // bonds souscrits au total
    uint256 public totalPaymentReceived;                   // USDC_wei total reçu

    // Activation
    uint256 public issueDate;          // timestamp d'activation
    uint256 public nextCouponDate;     // prochaine date de coupon (mode COUPON)
    uint256 public couponsPaid;        // nombre de coupons versés

    // Accrual des coupons (mode COUPON) — pattern "dividend per token"
    uint256 public totalCouponPerToken;                        // PRECISION-scaled, cumulatif
    uint256 public couponEligibleSupply;                       // bonds ayant droit aux prochains coupons
    mapping(address => uint256) private _couponCheckpoint;     // dernier totalCouponPerToken vu
    mapping(address => uint256) private _pendingCoupons;       // USDC_wei en attente de claim

    // Mode BULLET — montant de remboursement par bond à maturité
    uint256 public redemptionRate;   // PRECISION-scaled, USDC_wei par bond

    // Rachat anticipé (optionnel)
    uint256 public earlyBuybackPool;  // USDC_wei disponible pour rachat anticipé
    uint256 public earlyBuybackRate;  // PRECISION-scaled, USDC_wei par bond

    // Plateforme
    uint256 public setupFeeBps;
    uint256 public platformCouponFeeBps;
    BondaryFeeCollector public feeCollector;

    // ERC-3643 metadata and control plane
    string private _tokenName;
    string private _tokenSymbol;
    address private _tokenOnchainID;
    IIdentityRegistry private _identityRegistry;
    ICompliance private _tokenCompliance;
    mapping(address => bool) private _frozen;
    mapping(address => uint256) private _frozenTokens;
    bool private _forcedTransferInProgress;

    uint256 public constant UPGRADE_DELAY = 48 hours;
    address public pendingUpgradeImpl;
    uint256 public pendingUpgradeTimestamp;

    // Reserved storage slots for future upgrades — prevents storage collisions
    // when adding state variables in a new implementation.
    uint256[50] private __gap;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event Subscribed(address indexed investor, uint256 bonds, uint256 payment);
    event SubscriptionCancelled(address indexed investor, uint256 bonds, uint256 refund);
    event AllocationClaimed(address indexed investor, uint256 bonds);
    event BondActivated(uint256 totalBonds, uint256 totalRaised, uint256 setupFee);
    event BondFailed();
    event RefundClaimed(address indexed investor, uint256 amount);
    event CouponPaid(uint256 indexed period, uint256 totalAmount, uint256 platformFee);
    event CouponsClaimed(address indexed investor, uint256 amount);
    event BulletRepaid(uint256 totalAmount, uint256 platformFee);
    event PrincipalRepaid(uint256 principal);
    event BondsRedeemed(address indexed investor, uint256 bonds, uint256 payment);
    event EarlyBuybackOpened(uint256 totalFunds, uint256 ratePerBond);
    event EarlyBuybackRedeemed(address indexed investor, uint256 bonds, uint256 payment);
    event MaturityReached();
    event EmergencyRedemptionSet(uint256 redemptionRatePerBond);
    event EarlyBuybackPoolWithdrawn(uint256 amount);
    event StateChanged(State indexed oldState, State indexed newState);
    event UpgradeProposed(address indexed implementation, uint256 executableAt);
    event UpgradeCancelled(address indexed implementation);

    // ─────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyState(State _state) {
        require(state == _state, "Bond: invalid state");
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
        string  memory _name,
        string  memory _symbol,
        BondTerms calldata _terms,
        uint256 _setupFeeBps,
        uint256 _platformCouponFeeBps,
        address _compliance,
        address _feeCollector,
        address admin
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Validations
        require(admin != address(0),                              "Bond: zero admin");
        require(_terms.totalIssuance > 0,                        "Bond: zero issuance");
        require(_terms.softCap <= _terms.totalIssuance,          "Bond: softCap > totalIssuance");
        require(_terms.issuancePrice > 0,                        "Bond: zero price");
        require(_terms.faceValue > 0,                            "Bond: zero faceValue");
        require(_terms.couponRate > 0,                           "Bond: zero rate");
        require(_terms.couponRate < BPS_DENOMINATOR,             "Bond: rate >= 100%");
        // M-04 fix: COUPON mode bonds must have a meaningful coupon frequency.
        require(
            _terms.paymentMode == PaymentMode.BULLET || _terms.couponFrequency >= 1 days,
            "Bond: couponFrequency must be >= 1 day for COUPON mode"
        );
        require(_terms.maturityDate > block.timestamp,           "Bond: maturity in past");
        require(_terms.subscriptionEnd > block.timestamp,        "Bond: subscriptionEnd in past");
        require(_terms.subscriptionEnd < _terms.maturityDate,    "Bond: end after maturity");
        require(_terms.paymentToken != address(0),               "Bond: zero payment token");
        require(_terms.issuer != address(0),                     "Bond: zero issuer");
        require(_feeCollector != address(0),                     "Bond: zero feeCollector");
        require(_setupFeeBps < BPS_DENOMINATOR,                  "Bond: setup fee >= 100%");
        require(_platformCouponFeeBps < BPS_DENOMINATOR,         "Bond: platform fee >= 100%");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE, admin);
        _grantRole(ISSUER_ROLE, _terms.issuer);

        _tokenName           = _name;
        _tokenSymbol         = _symbol;
        terms                = _terms;
        setupFeeBps          = _setupFeeBps;
        platformCouponFeeBps = _platformCouponFeeBps;
        feeCollector         = BondaryFeeCollector(_feeCollector);
        state                = State.SUBSCRIPTION;

        _setIdentityRegistry(_compliance);
        _setCompliance(_compliance);
        emit UpdatedTokenInformation(_tokenName, _tokenSymbol, decimals(), TOKEN_VERSION, _tokenOnchainID);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ERC-20 : décimales et transferts
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev 0 décimales : 1 token = 1 obligation entière.
     *      Pas de fractions — chaque unité est un bond.
     */
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /**
     * @dev Surcharge ERC-20 :
     *      - Vérifie la conformité KYC/AML pour les transferts réguliers
     *      - Accrual des coupons avant tout mouvement de balance
     */
    function _update(address from, address to, uint256 value) internal override {
        // Conformité : uniquement pour les transferts (pas mint ni burn)
        if (!_forcedTransferInProgress) {
            if (from != address(0) && to != address(0)) {
                require(!paused(), "Pausable: paused");
                require(!_frozen[from] && !_frozen[to], "Bond: wallet frozen");
                require(value <= balanceOf(from) - _frozenTokens[from], "Bond: insufficient free balance");
                require(_identityRegistry.isVerified(from), "Bond: sender not compliant");
                require(_identityRegistry.isVerified(to), "Bond: recipient not compliant");
                require(_tokenCompliance.canTransfer(from, to, value), "Bond: compliance failure");
            } else if (from == address(0) && to != address(0)) {
                require(_identityRegistry.isVerified(to), "Bond: recipient not compliant");
                require(_tokenCompliance.canTransfer(address(0), to, value), "Bond: compliance failure");
            }
        } else if (to != address(0)) {
            require(_identityRegistry.isVerified(to), "Bond: recipient not compliant");
        }

        // Accrual coupons avant changement de balance
        if (terms.paymentMode == PaymentMode.COUPON && state == State.ACTIVE) {
            if (from != address(0)) _accrueCoupon(from);
            if (to   != address(0)) _accrueCoupon(to);
        }

        super._update(from, to, value);

        if (from == address(0) && to != address(0)) {
            _tokenCompliance.created(to, value);
        } else if (from != address(0) && to == address(0)) {
            _tokenCompliance.destroyed(from, value);
        } else if (from != address(0) && to != address(0)) {
            _tokenCompliance.transferred(from, to, value);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 1 : SUBSCRIPTION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Souscrire à l'émission obligataire.
     * @param bondAmount  Nombre de bonds entiers à acheter.
     *                    Le paiement = bondAmount × issuancePrice en USDC.
     */
    function subscribe(uint256 bondAmount)
        external
        nonReentrant
        whenNotPaused
        onlyState(State.SUBSCRIPTION)
    {
        require(block.timestamp < terms.subscriptionEnd, "Bond: subscription ended");
        require(_identityRegistry.isVerified(msg.sender), "Bond: not compliant");
        require(bondAmount > 0,                          "Bond: zero amount");

        // Respecter le hard cap
        uint256 remaining = terms.totalIssuance - totalSubscribed;
        require(remaining > 0, "Bond: fully subscribed");
        require(bondAmount <= remaining, "Bond: exceeds remaining capacity");

        uint256 payment = bondAmount * terms.issuancePrice;
        require(payment >= terms.minInvestment, "Bond: below min investment");

        subscriptions[msg.sender]    += bondAmount;
        paymentDeposited[msg.sender] += payment;
        totalSubscribed              += bondAmount;
        totalPaymentReceived         += payment;

        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), payment);

        emit Subscribed(msg.sender, bondAmount, payment);
    }

    /**
     * @notice Annuler sa souscription et récupérer le paiement.
     *         Uniquement en phase SUBSCRIPTION.
     * @dev Intentionally not whenNotPaused — investors must always be able to
     *      recover their funds even during an emergency pause.
     */
    function cancelSubscription() external nonReentrant onlyState(State.SUBSCRIPTION) {
        uint256 bonds   = subscriptions[msg.sender];
        uint256 payment = paymentDeposited[msg.sender];
        require(bonds > 0, "Bond: no subscription");

        subscriptions[msg.sender]    = 0;
        paymentDeposited[msg.sender] = 0;
        totalSubscribed              -= bonds;
        totalPaymentReceived         -= payment;

        IERC20(terms.paymentToken).safeTransfer(msg.sender, payment);

        emit SubscriptionCancelled(msg.sender, bonds, payment);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 2 : ACTIVATION → ACTIVE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Active l'émission obligataire.
     *         Prélève les frais de dossier, transfère les fonds à l'émetteur,
     *         démarre l'horloge des coupons.
     *         Conditions : subscriptionEnd passé OU hard cap atteint + soft cap validé.
     */
    function activateBond()
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
        onlyState(State.SUBSCRIPTION)
    {
        require(
            block.timestamp >= terms.subscriptionEnd || totalSubscribed >= terms.totalIssuance,
            "Bond: subscription still open"
        );
        require(totalSubscribed >= terms.softCap, "Bond: soft cap not reached");

        uint256 raised   = totalPaymentReceived;
        uint256 setupFee = (raised * setupFeeBps) / BPS_DENOMINATOR;
        uint256 proceeds = raised - setupFee;

        // Frais de dossier → FeeCollector
        if (setupFee > 0) {
            IERC20(terms.paymentToken).safeTransfer(address(feeCollector), setupFee);
            feeCollector.notifyFeeReceived(
                terms.paymentToken, setupFee, BondaryFeeCollector.FeeType.SETUP
            );
        }

        // Produit net → émetteur
        IERC20(terms.paymentToken).safeTransfer(terms.issuer, proceeds);

        issueDate            = terms.subscriptionEnd;
        nextCouponDate       = block.timestamp + terms.couponFrequency;
        couponEligibleSupply = totalSubscribed;

        _changeState(State.ACTIVE);
        emit BondActivated(totalSubscribed, raised, setupFee);
    }

    /**
     * @notice Déclare l'échec de la levée (soft cap non atteint).
     *         Les souscripteurs peuvent ensuite réclamer leur remboursement.
     */
    function failBond()
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.SUBSCRIPTION)
    {
        require(block.timestamp >= terms.subscriptionEnd, "Bond: subscription still open");
        require(totalSubscribed < terms.softCap,          "Bond: soft cap reached");

        _changeState(State.FAILED);
        emit BondFailed();
    }

    /**
     * @notice Réclamer les tokens après activation.
     *         Les investisseurs appellent cette fonction une fois la levée validée.
     *         Les coupons déjà versés avant cet appel sont crédités rétroactivement.
     */
    function claimAllocation() external nonReentrant {
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        uint256 bonds = subscriptions[msg.sender];
        require(bonds > 0,                         "Bond: no allocation");
        require(!allocationClaimed[msg.sender],    "Bond: already claimed");

        allocationClaimed[msg.sender] = true;

        // Mint : _update va appeler _accrueCoupon(to) avec balance=0 → aucun coupon perdu
        // mais le checkpoint sera mis à jour à totalCouponPerToken courant.
        // On corrige ensuite en créditant les coupons depuis l'activation.
        _mint(msg.sender, bonds);

        // Crédit rétroactif des coupons depuis le début du bond
        // (totalCouponPerToken à l'activation = 0 par définition du contrat).
        //
        // C-01 fix: when state == MATURED, _update() skips _accrueCoupon() because the
        // guard is (state == ACTIVE). The checkpoint therefore stays at 0. Without the
        // assignment below, a subsequent call to claimCoupons() / redeemBonds() would
        // invoke _accrueCoupon() with checkpoint=0 and recompute the same amount a second
        // time, letting the investor drain 2× their entitled coupons from the pool.
        if (terms.paymentMode == PaymentMode.COUPON && totalCouponPerToken > 0) {
            _pendingCoupons[msg.sender] += (bonds * totalCouponPerToken) / PRECISION;
            _couponCheckpoint[msg.sender] = totalCouponPerToken;
        }

        emit AllocationClaimed(msg.sender, bonds);
    }

    /**
     * @notice Remboursement en cas d'échec de la levée.
     */
    function claimRefund() external nonReentrant onlyState(State.FAILED) {
        uint256 payment = paymentDeposited[msg.sender];
        require(payment > 0, "Bond: no payment");

        paymentDeposited[msg.sender] = 0;
        subscriptions[msg.sender]    = 0;

        IERC20(terms.paymentToken).safeTransfer(msg.sender, payment);

        emit RefundClaimed(msg.sender, payment);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 3 : ACTIVE — Coupons (mode COUPON)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Verse un coupon aux détenteurs d'obligations.
     *         L'émetteur doit avoir approuvé le contrat pour le montant du coupon.
     *         Appelable par l'émetteur (ISSUER_ROLE) ou l'équipe Bondary (ADMIN_ROLE).
     *
     *         Montant attendu :
     *           totalSupply × faceValue × couponRate × couponFrequency
     *           ──────────────────────────────────────────────────────
     *                         BPS × YEAR_IN_SECONDS
     */
    function payCoupon() external nonReentrant onlyState(State.ACTIVE) {
        require(terms.paymentMode == PaymentMode.COUPON, "Bond: not coupon mode");
        // Only the issuer pays coupons — pulling from admin wallet would misdirect funds.
        require(hasRole(ISSUER_ROLE, msg.sender), "Bond: not issuer");
        require(block.timestamp >= nextCouponDate, "Bond: coupon not due");
        require(couponEligibleSupply > 0,          "Bond: no bonds in circulation");

        uint256 couponAmount = expectedCouponAmount();
        require(couponAmount > 0, "Bond: zero coupon");

        uint256 platformFee  = (couponAmount * platformCouponFeeBps) / BPS_DENOMINATOR;
        uint256 netCoupon    = couponAmount - platformFee;

        // Pull du montant brut depuis l'émetteur
        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), netCoupon);
        if (platformFee > 0) {
            IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(feeCollector), platformFee);
            feeCollector.notifyFeeReceived(
                terms.paymentToken, platformFee, BondaryFeeCollector.FeeType.COUPON
            );
        }

        // Mise à jour du compteur global (pattern dividend-per-token)
        totalCouponPerToken += (netCoupon * PRECISION) / couponEligibleSupply;

        couponsPaid++;
        nextCouponDate += terms.couponFrequency;

        emit CouponPaid(couponsPaid, couponAmount, platformFee);
    }

    /**
     * @notice Réclamer l'ensemble des coupons accumulés.
     */
    function claimCoupons() external nonReentrant {
        require(terms.paymentMode == PaymentMode.COUPON, "Bond: not coupon mode");
        require(_identityRegistry.isVerified(msg.sender), "Bond: holder not compliant");
        require(!_frozen[msg.sender], "Bond: wallet frozen");
        _accrueCoupon(msg.sender);

        uint256 amount = _pendingCoupons[msg.sender];
        require(amount > 0, "Bond: nothing to claim");

        _pendingCoupons[msg.sender] = 0;
        IERC20(terms.paymentToken).safeTransfer(msg.sender, amount);

        emit CouponsClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 4 : MATURED
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Signale que l'obligation a atteint sa maturité.
     *         N'importe qui peut l'appeler une fois la date passée.
     *         Bloque les nouvelles souscriptions et coupons.
     */
    function signalMaturity() external onlyState(State.ACTIVE) {
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        _changeState(State.MATURED);
        emit MaturityReached();
    }

    /**
     * @notice (Mode BULLET) Remboursement du principal + intérêts en une seule fois.
     *         L'émetteur dépose le montant total dû.
     *         Déclenche la transition vers MATURED.
     */
    function repayBullet() external nonReentrant onlyRole(ISSUER_ROLE) {
        require(terms.paymentMode == PaymentMode.BULLET, "Bond: not bullet mode");
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        require(couponEligibleSupply > 0, "Bond: no bonds");
        require(redemptionRate == 0, "Bond: already repaid");

        uint256 principal    = couponEligibleSupply * terms.faceValue;
        uint256 totalInterest = (principal * terms.couponRate *
            (terms.maturityDate - issueDate)) / (BPS_DENOMINATOR * YEAR_IN_SECONDS);

        uint256 platformFee  = (totalInterest * platformCouponFeeBps) / BPS_DENOMINATOR;
        uint256 netInterest  = totalInterest - platformFee;
        uint256 totalNet     = principal + netInterest;

        // Pull depuis l'émetteur
        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), totalNet);
        if (platformFee > 0) {
            IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(feeCollector), platformFee);
            feeCollector.notifyFeeReceived(
                terms.paymentToken, platformFee, BondaryFeeCollector.FeeType.REDEMPTION
            );
        }

        // Taux de rachat = montant net / nombre de bonds
        redemptionRate = (totalNet * PRECISION) / couponEligibleSupply;

        if (state == State.ACTIVE) _changeState(State.MATURED);
        emit BulletRepaid(totalNet + platformFee, platformFee);
    }

    /**
     * @notice (Mode COUPON) Remboursement du principal à maturité.
     *         Les coupons ont déjà été versés périodiquement.
     */
    function repayPrincipal() external nonReentrant onlyRole(ISSUER_ROLE) {
        require(terms.paymentMode == PaymentMode.COUPON, "Bond: not coupon mode");
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        require(couponEligibleSupply > 0, "Bond: no bonds");
        require(redemptionRate == 0, "Bond: already repaid");

        uint256 principal = couponEligibleSupply * terms.faceValue;

        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), principal);

        redemptionRate = (principal * PRECISION) / couponEligibleSupply;

        if (state == State.ACTIVE) _changeState(State.MATURED);
        emit PrincipalRepaid(principal);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 5 : Rachat final (MATURED → CLOSED)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Rembourser ses obligations à maturité.
     *         L'investisseur brûle ses bonds et récupère le principal (+ intérêts si BULLET).
     *         Les coupons non réclamés (mode COUPON) sont également versés.
     * @param bondAmount  Nombre de bonds à rembourser (rachat partiel possible).
     */
    function redeemBonds(uint256 bondAmount) external nonReentrant onlyState(State.MATURED) {
        require(bondAmount > 0,                         "Bond: zero amount");
        require(balanceOf(msg.sender) >= bondAmount,    "Bond: insufficient bonds");
        require(redemptionRate > 0,                     "Bond: principal not deposited");

        // Accrual des coupons restants (mode COUPON)
        if (terms.paymentMode == PaymentMode.COUPON) {
            _accrueCoupon(msg.sender);
        }

        uint256 payout = (bondAmount * redemptionRate) / PRECISION;

        // Burn des bonds
        _burnBondTokens(msg.sender, bondAmount);

        // Versement du principal (et intérêts si BULLET)
        IERC20(terms.paymentToken).safeTransfer(msg.sender, payout);

        // Coupons en attente (mode COUPON)
        uint256 pendingCoupon = _pendingCoupons[msg.sender];
        if (pendingCoupon > 0) {
            _pendingCoupons[msg.sender] = 0;
            IERC20(terms.paymentToken).safeTransfer(msg.sender, pendingCoupon);
        }

        emit BondsRedeemed(msg.sender, bondAmount, payout + pendingCoupon);

        // Fermeture automatique si tous les bonds sont rachetés
        if (couponEligibleSupply == 0) {
            _changeState(State.CLOSED);
        }
    }

    function setEmergencyRedemptionRate(uint256 rate)
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.MATURED)
    {
        require(redemptionRate == 0, "Bond: already repaid");
        require(block.timestamp >= terms.maturityDate + 30 days, "Bond: grace period not expired");
        redemptionRate = rate;
        emit EmergencyRedemptionSet(rate);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Rachat anticipé (optionnel, si earlyBuybackEnabled)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice L'émetteur ouvre une fenêtre de rachat anticipé.
     *         Dépose des fonds à un prix par bond défini.
     *         Les investisseurs qui le souhaitent peuvent vendre leurs bonds.
     * @param totalFunds    USDC_wei total déposé pour le rachat.
     * @param ratePerBond   USDC_wei par bond racheté.
     */
    function openEarlyBuyback(uint256 totalFunds, uint256 ratePerBond)
        external
        nonReentrant
        onlyRole(ISSUER_ROLE)
        onlyState(State.ACTIVE)
    {
        require(terms.earlyBuybackEnabled,  "Bond: buyback not enabled");
        require(totalFunds > 0,             "Bond: zero funds");
        require(ratePerBond > 0,            "Bond: zero rate");
        require(ratePerBond <= type(uint256).max / PRECISION, "Bond: rate too high");
        require(block.timestamp < terms.maturityDate, "Bond: already matured");

        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), totalFunds);

        // Prevent silent rate change while investors are waiting to redeem.
        if (earlyBuybackPool > 0) {
            require(
                ratePerBond * PRECISION == earlyBuybackRate,
                "Bond: cannot change rate while pool active"
            );
        }
        earlyBuybackPool += totalFunds;
        earlyBuybackRate  = ratePerBond * PRECISION;

        emit EarlyBuybackOpened(totalFunds, ratePerBond);
    }

    /**
     * @notice Céder ses bonds dans une fenêtre de rachat anticipé.
     * @param bondAmount  Nombre de bonds à vendre à l'émetteur.
     */
    function redeemEarly(uint256 bondAmount) external nonReentrant onlyState(State.ACTIVE) {
        require(earlyBuybackPool > 0,              "Bond: no buyback pool");
        require(bondAmount > 0,                    "Bond: zero amount");
        require(balanceOf(msg.sender) >= bondAmount, "Bond: insufficient bonds");

        uint256 payout = (bondAmount * earlyBuybackRate) / PRECISION;
        require(payout <= earlyBuybackPool,        "Bond: pool exhausted");

        // Accrual des coupons avant burn
        if (terms.paymentMode == PaymentMode.COUPON) {
            _accrueCoupon(msg.sender);
        }

        earlyBuybackPool -= payout;
        _burnBondTokens(msg.sender, bondAmount);
        IERC20(terms.paymentToken).safeTransfer(msg.sender, payout);

        emit EarlyBuybackRedeemed(msg.sender, bondAmount, payout);
    }

    function withdrawEarlyBuybackPool() external nonReentrant onlyRole(ISSUER_ROLE) {
        require(
            state == State.MATURED || state == State.CLOSED || state == State.FAILED,
            "Bond: buyback pool still active"
        );
        uint256 remaining = earlyBuybackPool;
        require(remaining > 0, "Bond: empty buyback pool");
        earlyBuybackPool = 0;
        IERC20(terms.paymentToken).safeTransfer(terms.issuer, remaining);
        emit EarlyBuybackPoolWithdrawn(remaining);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Accrual des coupons (interne)
    // ─────────────────────────────────────────────────────────────────────────

    function _accrueCoupon(address account) internal {
        uint256 checkpoint = _couponCheckpoint[account];
        if (totalCouponPerToken > checkpoint) {
            uint256 earned = (balanceOf(account) * (totalCouponPerToken - checkpoint)) / PRECISION;
            _pendingCoupons[account] += earned;
            // G-01 fix: write checkpoint only when there is something to update.
            _couponCheckpoint[account] = totalCouponPerToken;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Montant brut du prochain coupon à verser (mode COUPON).
     */
    function expectedCouponAmount() public view returns (uint256) {
        return (couponEligibleSupply * terms.faceValue * terms.couponRate * terms.couponFrequency)
            / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
    }

    /**
     * @notice Montant total dû à maturité pour l'émetteur (mode BULLET).
     *         principal + intérêts calculés sur la durée totale.
     */
    function expectedBulletRepayment() public view returns (uint256) {
        if (issueDate == 0) return 0;
        uint256 principal = couponEligibleSupply * terms.faceValue;
        uint256 duration  = terms.maturityDate - issueDate;
        uint256 interest  = (principal * terms.couponRate * duration)
            / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
        return principal + interest;
    }

    /**
     * @notice Coupons accumulés et non réclamés d'un investisseur.
     */
    function pendingCoupons(address account) external view returns (uint256) {
        uint256 checkpoint = _couponCheckpoint[account];
        uint256 accruing   = 0;
        if (totalCouponPerToken > checkpoint) {
            accruing = (balanceOf(account) * (totalCouponPerToken - checkpoint)) / PRECISION;
        }
        return _pendingCoupons[account] + accruing;
    }

    /**
     * @notice Retourne les termes complets de l'obligation comme struct (utile en cross-contract).
     */
    function getTerms() external view returns (BondTerms memory) {
        return terms;
    }

    /**
     * @notice Montant total levé pendant la souscription (brut, avant frais).
     */
    function totalRaised() external view returns (uint256) {
        return totalPaymentReceived;
    }

    // ---------------------------------------------------------------------
    // ERC-3643 token API
    // ---------------------------------------------------------------------

    function version() external pure override returns (string memory) {
        return TOKEN_VERSION;
    }

    function onchainID() external view override returns (address) {
        return _tokenOnchainID;
    }

    function identityRegistry() external view override returns (IIdentityRegistry) {
        return _identityRegistry;
    }

    function compliance() external view override returns (ICompliance) {
        return _tokenCompliance;
    }

    function isFrozen(address userAddress) external view override returns (bool) {
        return _frozen[userAddress];
    }

    function getFrozenTokens(address userAddress) external view override returns (uint256) {
        return _frozenTokens[userAddress];
    }

    function setName(string calldata newName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(newName).length > 0, "Bond: empty name");
        _tokenName = newName;
        emit UpdatedTokenInformation(_tokenName, _tokenSymbol, decimals(), TOKEN_VERSION, _tokenOnchainID);
    }

    function setSymbol(string calldata newSymbol) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(newSymbol).length > 0, "Bond: empty symbol");
        _tokenSymbol = newSymbol;
        emit UpdatedTokenInformation(_tokenName, _tokenSymbol, decimals(), TOKEN_VERSION, _tokenOnchainID);
    }

    function setOnchainID(address newOnchainID) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenOnchainID = newOnchainID;
        emit UpdatedTokenInformation(_tokenName, _tokenSymbol, decimals(), TOKEN_VERSION, _tokenOnchainID);
    }

    function setIdentityRegistry(address newIdentityRegistry) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setIdentityRegistry(newIdentityRegistry);
    }

    function setCompliance(address newCompliance) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCompliance(newCompliance);
    }

    function setAddressFrozen(address userAddress, bool freeze) public override onlyRole(AGENT_ROLE) {
        _frozen[userAddress] = freeze;
        emit AddressFrozen(userAddress, freeze, msg.sender);
    }

    function freezePartialTokens(address userAddress, uint256 amount) public override onlyRole(AGENT_ROLE) {
        _freezePartialTokens(userAddress, amount);
    }

    function unfreezePartialTokens(address userAddress, uint256 amount) public override onlyRole(AGENT_ROLE) {
        _unfreezePartialTokens(userAddress, amount);
    }

    function forcedTransfer(address from, address to, uint256 amount)
        public
        override
        onlyRole(AGENT_ROLE)
        returns (bool)
    {
        _forceTransferTokens(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public override onlyRole(AGENT_ROLE) {
        // M-01 fix: FAILED state must not allow minting of unbacked tokens while
        // investors are actively claiming refunds via claimRefund().
        require(
            state == State.SUBSCRIPTION || state == State.ACTIVE,
            "Bond: mint only allowed during subscription or active"
        );
        // Keep couponEligibleSupply in sync so future coupons and redemptionRate
        // are calculated over the correct supply including agent-minted bonds.
        couponEligibleSupply += amount;
        _mint(to, amount);
    }

    function burn(address userAddress, uint256 amount) public override onlyRole(AGENT_ROLE) {
        _agentBurnBondTokens(userAddress, amount);
    }

    function recoveryAddress(address lostWallet, address newWallet, address investorOnchainID)
        external
        override
        onlyRole(AGENT_ROLE)
        returns (bool)
    {
        require(balanceOf(lostWallet) > 0, "Bond: no tokens to recover");
        require(newWallet != address(0) && newWallet != lostWallet, "Bond: invalid recovery wallet");

        IIdentity recoveredIdentity = IIdentity(investorOnchainID);
        bytes32 walletKey = keccak256(abi.encode(newWallet));
        require(recoveredIdentity.keyHasPurpose(walletKey, 1), "Bond: recovery not possible");

        uint16 country = _identityRegistry.investorCountry(lostWallet);
        try _identityRegistry.registerIdentity(newWallet, recoveredIdentity, country) {}
        catch {
            require(_identityRegistry.isVerified(newWallet), "Bond: new wallet not compliant");
        }

        uint256 recoveredBalance = balanceOf(lostWallet);
        uint256 frozenAmount = _frozenTokens[lostWallet];
        bool wasFrozen = _frozen[lostWallet];

        _forceTransferTokens(lostWallet, newWallet, recoveredBalance);

        if (frozenAmount > 0) {
            _freezePartialTokens(newWallet, frozenAmount);
        }
        if (wasFrozen) {
            _frozen[newWallet] = true;
            emit AddressFrozen(newWallet, true, msg.sender);
        }

        try _identityRegistry.deleteIdentity(lostWallet) {}
        catch {}

        emit RecoverySuccess(lostWallet, newWallet, investorOnchainID);
        return true;
    }

    function batchTransfer(address[] calldata toList, uint256[] calldata amounts) external override {
        require(toList.length == amounts.length, "Bond: length mismatch");
        require(toList.length <= MAX_BATCH_SIZE,  "Bond: batch too large");
        for (uint256 i = 0; i < toList.length; i++) {
            transfer(toList[i], amounts[i]);
        }
    }

    function batchForcedTransfer(
        address[] calldata fromList,
        address[] calldata toList,
        uint256[] calldata amounts
    ) external override {
        require(fromList.length == toList.length && fromList.length == amounts.length, "Bond: length mismatch");
        require(fromList.length <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < fromList.length; i++) {
            forcedTransfer(fromList[i], toList[i], amounts[i]);
        }
    }

    function batchMint(address[] calldata toList, uint256[] calldata amounts) external override {
        require(toList.length == amounts.length, "Bond: length mismatch");
        require(toList.length <= MAX_BATCH_SIZE,  "Bond: batch too large");
        for (uint256 i = 0; i < toList.length; i++) {
            mint(toList[i], amounts[i]);
        }
    }

    function batchBurn(address[] calldata userAddresses, uint256[] calldata amounts) external override {
        require(userAddresses.length == amounts.length, "Bond: length mismatch");
        require(userAddresses.length <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < userAddresses.length; i++) {
            burn(userAddresses[i], amounts[i]);
        }
    }

    function batchSetAddressFrozen(address[] calldata userAddresses, bool[] calldata freeze) external override {
        require(userAddresses.length == freeze.length, "Bond: length mismatch");
        require(userAddresses.length <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < userAddresses.length; i++) {
            setAddressFrozen(userAddresses[i], freeze[i]);
        }
    }

    function batchFreezePartialTokens(address[] calldata userAddresses, uint256[] calldata amounts)
        external
        override
    {
        require(userAddresses.length == amounts.length, "Bond: length mismatch");
        require(userAddresses.length <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < userAddresses.length; i++) {
            freezePartialTokens(userAddresses[i], amounts[i]);
        }
    }

    function batchUnfreezePartialTokens(address[] calldata userAddresses, uint256[] calldata amounts)
        external
        override
    {
        require(userAddresses.length == amounts.length, "Bond: length mismatch");
        require(userAddresses.length <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < userAddresses.length; i++) {
            unfreezePartialTokens(userAddresses[i], amounts[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Sécurité
    // ─────────────────────────────────────────────────────────────────────────

    function pause() external override onlyRole(AGENT_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(AGENT_ROLE) {
        _unpause();
    }

    function proposeUpgrade(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingUpgradeImpl == address(0), "Bond: upgrade already pending");
        require(newImplementation != address(0), "Bond: zero implementation");
        require(newImplementation.code.length > 0, "Bond: implementation not contract");
        pendingUpgradeImpl = newImplementation;
        pendingUpgradeTimestamp = block.timestamp + UPGRADE_DELAY;
        emit UpgradeProposed(newImplementation, pendingUpgradeTimestamp);
    }

    function cancelUpgrade() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldPending = pendingUpgradeImpl;
        require(oldPending != address(0), "Bond: no upgrade pending");
        pendingUpgradeImpl = address(0);
        pendingUpgradeTimestamp = 0;
        emit UpgradeCancelled(oldPending);
    }

    function _setIdentityRegistry(address newIdentityRegistry) internal {
        require(newIdentityRegistry != address(0), "Bond: zero identity registry");
        _identityRegistry = IIdentityRegistry(newIdentityRegistry);
        emit IdentityRegistryAdded(newIdentityRegistry);
    }

    function _setCompliance(address newCompliance) internal {
        require(newCompliance != address(0), "Bond: zero compliance");
        if (address(_tokenCompliance) != address(0)) {
            try _tokenCompliance.unbindToken(address(this)) {}
            catch {}
        }
        _tokenCompliance = ICompliance(newCompliance);
        _tokenCompliance.bindToken(address(this));
        emit ComplianceAdded(newCompliance);
    }

    function _freezePartialTokens(address userAddress, uint256 amount) internal {
        require(userAddress != address(0), "Bond: zero user");
        require(balanceOf(userAddress) >= _frozenTokens[userAddress] + amount, "Bond: amount exceeds balance");
        _frozenTokens[userAddress] += amount;
        emit TokensFrozen(userAddress, amount);
    }

    function _unfreezePartialTokens(address userAddress, uint256 amount) internal {
        require(_frozenTokens[userAddress] >= amount, "Bond: amount exceeds frozen");
        _frozenTokens[userAddress] -= amount;
        emit TokensUnfrozen(userAddress, amount);
    }

    function _forceTransferTokens(address from, address to, uint256 amount) internal {
        require(balanceOf(from) >= amount, "Bond: insufficient bonds");

        uint256 freeBalance = balanceOf(from) - _frozenTokens[from];
        if (amount > freeBalance) {
            uint256 tokensToUnfreeze = amount - freeBalance;
            _frozenTokens[from] -= tokensToUnfreeze;
            emit TokensUnfrozen(from, tokensToUnfreeze);
        }

        _forcedTransferInProgress = true;
        _transfer(from, to, amount);
        _forcedTransferInProgress = false;
    }

    function _burnBondTokens(address userAddress, uint256 amount) internal {
        require(balanceOf(userAddress) >= amount, "Bond: insufficient bonds");
        if (state == State.ACTIVE) {
            require(_identityRegistry.isVerified(userAddress), "Bond: holder not compliant");
            require(!_frozen[userAddress], "Bond: wallet frozen");
        }
        require(amount <= balanceOf(userAddress) - _frozenTokens[userAddress], "Bond: insufficient free balance");

        _decreaseCouponEligibleSupply(amount);

        _burn(userAddress, amount);
    }

    function _agentBurnBondTokens(address userAddress, uint256 amount) internal {
        require(balanceOf(userAddress) >= amount, "Bond: insufficient bonds");

        // H-01 fix: accrue pending coupons before reducing balance so the investor
        // does not permanently lose earned-but-unclaimed coupon funds on a forced burn.
        if (terms.paymentMode == PaymentMode.COUPON && state == State.ACTIVE) {
            _accrueCoupon(userAddress);
        }

        uint256 freeBalance = balanceOf(userAddress) - _frozenTokens[userAddress];
        if (amount > freeBalance) {
            uint256 tokensToUnfreeze = amount - freeBalance;
            _frozenTokens[userAddress] -= tokensToUnfreeze;
            emit TokensUnfrozen(userAddress, tokensToUnfreeze);
        }

        _decreaseCouponEligibleSupply(amount);

        _burn(userAddress, amount);
    }

    function _decreaseCouponEligibleSupply(uint256 amount) internal {
        if (couponEligibleSupply == 0) return;
        if (amount >= couponEligibleSupply) {
            couponEligibleSupply = 0;
        } else {
            couponEligibleSupply -= amount;
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newImplementation == pendingUpgradeImpl, "Bond: upgrade not proposed");
        require(block.timestamp >= pendingUpgradeTimestamp, "Bond: upgrade timelocked");
        pendingUpgradeImpl = address(0);
        pendingUpgradeTimestamp = 0;
    }

    function _changeState(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
    }
}
