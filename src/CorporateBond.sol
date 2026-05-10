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
 * @notice Token ERC-20 representant une obligation corporate tokenisee.
 *
 *  Modele economique :
 *    1 bond token = 1 unite de nominal (ex: 1 USDC de dette).
 *    Les tokens representent une creance, pas une part de vault.
 *    Decimales = 0 -> chaque token est une obligation entiere.
 *
 *  Cycle de vie :
 *    SUBSCRIPTION -> souscription ouverte (investisseurs deposent les fonds)
 *    ACTIVE       -> emission validee, tokens mintes, fonds verses a l'emetteur
 *    MATURED      -> maturite atteinte, remboursement du principal possible
 *    CLOSED       -> tous les tokens rachetes, obligation cloturee
 *    FAILED       -> soft cap non atteint, remboursement integral des souscripteurs
 *
 *  Deux modes de paiement configurables a l'emission :
 *    COUPON : interets verses periodiquement (trimestre/semestre/annuel)
 *             + principal rembourse a maturite
 *    BULLET : aucun paiement intermediaire, principal + interets totaux a maturite
 *
 *  Security token (MiFID II) :
 *    Tous les transferts verifient ComplianceManager.isVerified() pour from ET to.
 *    Seules les adresses KYC validees et non blacklistees peuvent detenir le token.
 *
 *  Coupon accrual (mode COUPON) :
 *    Pattern "dividend per token" : les coupons s'accumulent dans un compteur global
 *    totalCouponPerToken. Chaque transfert declenche l'accrual pour les deux parties.
 *    Les investisseurs reclament leurs coupons accumules via claimCoupons().
 *
 *  --- Audit H1 fixes (mai 2026) ---------------------------------------------
 *    S-01  repayPrincipal() paie automatiquement le coupon-stub pour la periode
 *          [lastCouponDate, maturityDate]. Avant : prorata perdu pour les
 *          investisseurs. Voir finalCouponPaid + repayPrincipal() ci-dessous.
 *
 *    S-02  mint() AGENT plafonne a AGENT_MINT_CAP_BPS (1%) de totalIssuance par
 *          fenetre glissante de 24h. Evite la dilution massive si AGENT_ROLE
 *          est compromis. SUBSCRIPTION : pas de cap (phase d'allocation).
 *
 *    S-03  setEmergencyRedemptionRate remplacee par flux propose/execute avec
 *          timelock 7 jours. Empeche un admin compromis de fixer un taux
 *          arbitrairement bas et de le declencher immediatement.
 *
 *    S-04  UPGRADE_DELAY 48h -> 7 jours. Aligne sur les standards de l'industrie
 *          security token (Securitize, Maple, Tokeny T-REX) qui utilisent 7-14j
 *          minimum pour les contrats detenant des fonds investisseurs.
 *  --------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    //  Constantes
    // -------------------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant AGENT_ROLE  = keccak256("AGENT_ROLE");

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant YEAR_IN_SECONDS  = 365 days;
    uint256 public constant MAX_BATCH_SIZE   = 200;    // DoS protection on batch calls
    uint256 public constant PRECISION        = 1e18;
    string  public constant TOKEN_VERSION    = "1.1.0-erc3643";

    /// @notice S-04 fix: timelock pour les upgrades UUPS. Aligne sur les standards
    ///         de l'industrie security token (Securitize, Tokeny T-REX, Maple).
    uint256 public constant UPGRADE_DELAY = 7 days;

    /// @notice S-02 fix: plafond de mint AGENT_ROLE par fenetre glissante de 24h,
    ///         exprime en BPS de terms.totalIssuance. Empeche la dilution massive
    ///         si AGENT_ROLE est compromis.
    uint256 public constant AGENT_MINT_CAP_BPS = 100; // 1.0% de totalIssuance par jour

    /// @notice S-03 fix: timelock sur la fixation du taux de remboursement
    ///         d'urgence. Donne 7 jours aux investisseurs pour reagir si le taux
    ///         propose est manifestement injuste.
    uint256 public constant EMERGENCY_REDEMPTION_DELAY = 7 days;

    /// @notice Periode de grace apres la maturite avant qu'un taux d'urgence
    ///         puisse etre propose (l'emetteur garde 30j pour deposer le principal).
    uint256 public constant EMERGENCY_GRACE_PERIOD = 30 days;

    // -------------------------------------------------------------------------
    //  Types
    // -------------------------------------------------------------------------

    enum State { SUBSCRIPTION, ACTIVE, MATURED, CLOSED, FAILED }

    enum PaymentMode { COUPON, BULLET }

    struct BondTerms {
        uint256 faceValue;           // USDC_wei par bond entier (ex: 1e6 = 1 USDC)
        uint256 totalIssuance;       // nombre total de bonds a emettre (entiers)
        uint256 softCap;             // minimum de bonds pour valider la levee
        uint256 issuancePrice;       // USDC_wei par bond a la souscription
        uint256 minInvestment;       // montant minimum en USDC_wei (ex: 50e6 = 50 USDC)
        uint256 couponRate;          // taux annuel en BPS (ex: 800 = 8.00 %)
        uint256 maturityDate;        // timestamp d'echeance
        uint256 couponFrequency;     // intervalle en secondes (ex: 90 days = trimestriel)
        PaymentMode paymentMode;     // COUPON ou BULLET
        bool earlyBuybackEnabled;    // l'emetteur peut-il racheter avant maturite ?
        uint256 subscriptionEnd;     // timestamp de fin de souscription
        address paymentToken;        // USDC ou EURC
        address issuer;              // adresse de l'emetteur (recoit les fonds leves)
    }

    // -------------------------------------------------------------------------
    //  Storage
    // -------------------------------------------------------------------------

    BondTerms public terms;
    State     public state;

    mapping(address => uint256) public subscriptions;
    mapping(address => uint256) public paymentDeposited;
    mapping(address => bool)    public allocationClaimed;
    uint256 public totalSubscribed;
    uint256 public totalPaymentReceived;

    uint256 public issueDate;
    uint256 public nextCouponDate;
    uint256 public couponsPaid;

    uint256 public totalCouponPerToken;
    uint256 public couponEligibleSupply;
    mapping(address => uint256) private _couponCheckpoint;
    mapping(address => uint256) private _pendingCoupons;

    uint256 public redemptionRate;

    uint256 public earlyBuybackPool;
    uint256 public earlyBuybackRate;

    uint256 public setupFeeBps;
    uint256 public platformCouponFeeBps;
    BondaryFeeCollector public feeCollector;

    string private _tokenName;
    string private _tokenSymbol;
    address private _tokenOnchainID;
    IIdentityRegistry private _identityRegistry;
    ICompliance private _tokenCompliance;
    mapping(address => bool) private _frozen;
    mapping(address => uint256) private _frozenTokens;
    bool private _forcedTransferInProgress;

    address public pendingUpgradeImpl;
    uint256 public pendingUpgradeTimestamp;

    // --- H1 storage additions -------------------------------------------------
    /// @notice S-02 : debut de la fenetre glissante 24h pour le cap de mint AGENT.
    uint256 private _agentMintWindowStart;
    /// @notice S-02 : montant minte par AGENT dans la fenetre courante.
    uint256 private _agentMintInWindow;
    /// @notice S-01 : drapeau anti-double-paiement du coupon-stub final.
    bool public finalCouponPaid;
    /// @notice S-03 : taux de remboursement d'urgence propose en attente.
    uint256 public proposedEmergencyRedemptionRate;
    /// @notice S-03 : timestamp a partir duquel la proposition peut etre executee.
    uint256 public proposedEmergencyRedemptionTimestamp;

    // Reserved storage slots for future upgrades. H1: shrunk from 50 to 45.
    uint256[45] private __gap;

    // -------------------------------------------------------------------------
    //  Events
    // -------------------------------------------------------------------------

    event Subscribed(address indexed investor, uint256 bonds, uint256 payment);
    event SubscriptionCancelled(address indexed investor, uint256 bonds, uint256 refund);
    event AllocationClaimed(address indexed investor, uint256 bonds);
    event BondActivated(uint256 totalBonds, uint256 totalRaised, uint256 setupFee);
    event BondFailed();
    event RefundClaimed(address indexed investor, uint256 amount);
    event CouponPaid(uint256 indexed period, uint256 totalAmount, uint256 platformFee);
    event FinalCouponPaid(uint256 indexed period, uint256 stubPeriod, uint256 totalAmount, uint256 platformFee);
    event CouponsClaimed(address indexed investor, uint256 amount);
    event BulletRepaid(uint256 totalAmount, uint256 platformFee);
    event PrincipalRepaid(uint256 principal);
    event BondsRedeemed(address indexed investor, uint256 bonds, uint256 payment);
    event EarlyBuybackOpened(uint256 totalFunds, uint256 ratePerBond);
    event EarlyBuybackRedeemed(address indexed investor, uint256 bonds, uint256 payment);
    event MaturityReached();
    event EmergencyRedemptionProposed(uint256 rate, uint256 executableAt);
    event EmergencyRedemptionExecuted(uint256 rate);
    event EmergencyRedemptionCancelled(uint256 rate);
    event EarlyBuybackPoolWithdrawn(uint256 amount);
    event StateChanged(State indexed oldState, State indexed newState);
    event UpgradeProposed(address indexed implementation, uint256 executableAt);
    event UpgradeCancelled(address indexed implementation);
    event IdentityRecoveryFallback(address indexed wallet, string action);
    event AgentMintCapWindow(uint256 windowStart, uint256 mintedInWindow, uint256 cap);

    modifier onlyState(State _state) {
        require(state == _state, "Bond: invalid state");
        _;
    }

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

        require(admin != address(0),                              "Bond: zero admin");
        require(_terms.totalIssuance > 0,                        "Bond: zero issuance");
        require(_terms.softCap <= _terms.totalIssuance,          "Bond: softCap > totalIssuance");
        require(_terms.issuancePrice > 0,                        "Bond: zero price");
        require(_terms.faceValue > 0,                            "Bond: zero faceValue");
        require(_terms.couponRate > 0,                           "Bond: zero rate");
        require(_terms.couponRate < BPS_DENOMINATOR,             "Bond: rate >= 100%");
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
        _setComplianceInitial(_compliance);
        emit UpdatedTokenInformation(_tokenName, _tokenSymbol, decimals(), TOKEN_VERSION, _tokenOnchainID);
    }

    function decimals() public pure override returns (uint8) { return 0; }
    function name() public view override returns (string memory) { return _tokenName; }
    function symbol() public view override returns (string memory) { return _tokenSymbol; }

    function _update(address from, address to, uint256 value) internal override {
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

    // ------- SUBSCRIPTION ----------------------------------------------------

    function subscribe(uint256 bondAmount)
        external
        nonReentrant
        whenNotPaused
        onlyState(State.SUBSCRIPTION)
    {
        require(block.timestamp < terms.subscriptionEnd, "Bond: subscription ended");
        require(_identityRegistry.isVerified(msg.sender), "Bond: not compliant");
        require(bondAmount > 0,                          "Bond: zero amount");

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

    // ------- ACTIVATION ------------------------------------------------------

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

        if (setupFee > 0) {
            IERC20(terms.paymentToken).safeTransfer(address(feeCollector), setupFee);
            feeCollector.notifyFeeReceived(terms.paymentToken, setupFee, BondaryFeeCollector.FeeType.SETUP);
        }
        IERC20(terms.paymentToken).safeTransfer(terms.issuer, proceeds);

        issueDate            = terms.subscriptionEnd;
        nextCouponDate       = block.timestamp + terms.couponFrequency;
        couponEligibleSupply = totalSubscribed;

        _changeState(State.ACTIVE);
        emit BondActivated(totalSubscribed, raised, setupFee);
    }

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

    function claimAllocation() external nonReentrant {
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        uint256 bonds = subscriptions[msg.sender];
        require(bonds > 0,                         "Bond: no allocation");
        require(!allocationClaimed[msg.sender],    "Bond: already claimed");

        allocationClaimed[msg.sender] = true;
        _mint(msg.sender, bonds);

        if (terms.paymentMode == PaymentMode.COUPON && totalCouponPerToken > 0) {
            _pendingCoupons[msg.sender] += (bonds * totalCouponPerToken) / PRECISION;
            _couponCheckpoint[msg.sender] = totalCouponPerToken;
        }
        emit AllocationClaimed(msg.sender, bonds);
    }

    function claimRefund() external nonReentrant onlyState(State.FAILED) {
        uint256 payment = paymentDeposited[msg.sender];
        require(payment > 0, "Bond: no payment");
        paymentDeposited[msg.sender] = 0;
        subscriptions[msg.sender]    = 0;
        IERC20(terms.paymentToken).safeTransfer(msg.sender, payment);
        emit RefundClaimed(msg.sender, payment);
    }

    // ------- COUPONS ---------------------------------------------------------

    function payCoupon() external nonReentrant onlyState(State.ACTIVE) {
        require(terms.paymentMode == PaymentMode.COUPON, "Bond: not coupon mode");
        require(hasRole(ISSUER_ROLE, msg.sender), "Bond: not issuer");
        require(block.timestamp >= nextCouponDate, "Bond: coupon not due");
        require(couponEligibleSupply > 0,          "Bond: no bonds in circulation");

        uint256 couponAmount = expectedCouponAmount();
        require(couponAmount > 0, "Bond: zero coupon");

        uint256 platformFee = (couponAmount * platformCouponFeeBps) / BPS_DENOMINATOR;
        uint256 netCoupon   = couponAmount - platformFee;

        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), netCoupon);
        if (platformFee > 0) {
            IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(feeCollector), platformFee);
            feeCollector.notifyFeeReceived(terms.paymentToken, platformFee, BondaryFeeCollector.FeeType.COUPON);
        }
        totalCouponPerToken += (netCoupon * PRECISION) / couponEligibleSupply;
        couponsPaid++;
        nextCouponDate += terms.couponFrequency;
        emit CouponPaid(couponsPaid, couponAmount, platformFee);
    }

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

    // ------- MATURED ---------------------------------------------------------

    function signalMaturity() external onlyState(State.ACTIVE) {
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        _changeState(State.MATURED);
        emit MaturityReached();
    }

    function repayBullet() external nonReentrant onlyRole(ISSUER_ROLE) {
        require(terms.paymentMode == PaymentMode.BULLET, "Bond: not bullet mode");
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        require(couponEligibleSupply > 0, "Bond: no bonds");
        require(redemptionRate == 0, "Bond: already repaid");

        uint256 principal     = couponEligibleSupply * terms.faceValue;
        uint256 totalInterest = (principal * terms.couponRate * (terms.maturityDate - issueDate)) /
            (BPS_DENOMINATOR * YEAR_IN_SECONDS);
        uint256 platformFee   = (totalInterest * platformCouponFeeBps) / BPS_DENOMINATOR;
        uint256 netInterest   = totalInterest - platformFee;
        uint256 totalNet      = principal + netInterest;

        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), totalNet);
        if (platformFee > 0) {
            IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(feeCollector), platformFee);
            feeCollector.notifyFeeReceived(terms.paymentToken, platformFee, BondaryFeeCollector.FeeType.REDEMPTION);
        }
        redemptionRate = (totalNet * PRECISION) / couponEligibleSupply;
        if (state == State.ACTIVE) _changeState(State.MATURED);
        emit BulletRepaid(totalNet + platformFee, platformFee);
    }

    /// @notice (Mode COUPON) Repay principal + S-01 stub coupon for the period
    ///         [lastCouponDate, maturityDate].
    function repayPrincipal() external nonReentrant onlyRole(ISSUER_ROLE) {
        require(terms.paymentMode == PaymentMode.COUPON, "Bond: not coupon mode");
        require(state == State.ACTIVE || state == State.MATURED, "Bond: invalid state");
        require(block.timestamp >= terms.maturityDate, "Bond: not matured");
        require(couponEligibleSupply > 0, "Bond: no bonds");
        require(redemptionRate == 0, "Bond: already repaid");

        if (!finalCouponPaid) {
            uint256 lastCouponDate = couponsPaid == 0
                ? issueDate
                : nextCouponDate - terms.couponFrequency;

            if (terms.maturityDate > lastCouponDate) {
                uint256 stubPeriod = terms.maturityDate - lastCouponDate;
                uint256 stubGross  = (couponEligibleSupply * terms.faceValue * terms.couponRate * stubPeriod) /
                    (BPS_DENOMINATOR * YEAR_IN_SECONDS);

                if (stubGross > 0) {
                    uint256 stubFee = (stubGross * platformCouponFeeBps) / BPS_DENOMINATOR;
                    uint256 stubNet = stubGross - stubFee;

                    IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), stubNet);
                    if (stubFee > 0) {
                        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(feeCollector), stubFee);
                        feeCollector.notifyFeeReceived(terms.paymentToken, stubFee, BondaryFeeCollector.FeeType.COUPON);
                    }
                    totalCouponPerToken += (stubNet * PRECISION) / couponEligibleSupply;
                    couponsPaid++;
                    emit FinalCouponPaid(couponsPaid, stubPeriod, stubGross, stubFee);
                }
            }
            finalCouponPaid = true;
        }

        uint256 principal = couponEligibleSupply * terms.faceValue;
        IERC20(terms.paymentToken).safeTransferFrom(msg.sender, address(this), principal);
        redemptionRate = (principal * PRECISION) / couponEligibleSupply;
        if (state == State.ACTIVE) _changeState(State.MATURED);
        emit PrincipalRepaid(principal);
    }

    // ------- REDEEM ----------------------------------------------------------

    function redeemBonds(uint256 bondAmount) external nonReentrant onlyState(State.MATURED) {
        require(bondAmount > 0,                         "Bond: zero amount");
        require(balanceOf(msg.sender) >= bondAmount,    "Bond: insufficient bonds");
        require(redemptionRate > 0,                     "Bond: principal not deposited");

        if (terms.paymentMode == PaymentMode.COUPON) {
            _accrueCoupon(msg.sender);
        }
        uint256 payout = (bondAmount * redemptionRate) / PRECISION;
        _burnBondTokens(msg.sender, bondAmount);
        IERC20(terms.paymentToken).safeTransfer(msg.sender, payout);

        uint256 pendingCoupon = _pendingCoupons[msg.sender];
        if (pendingCoupon > 0) {
            _pendingCoupons[msg.sender] = 0;
            IERC20(terms.paymentToken).safeTransfer(msg.sender, pendingCoupon);
        }
        emit BondsRedeemed(msg.sender, bondAmount, payout + pendingCoupon);
        if (couponEligibleSupply == 0) {
            _changeState(State.CLOSED);
        }
    }

    // ------- S-03 : Emergency redemption rate avec timelock 7 jours ----------

    function proposeEmergencyRedemptionRate(uint256 rate)
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.MATURED)
    {
        require(redemptionRate == 0, "Bond: already repaid");
        require(rate > 0, "Bond: zero rate");
        require(
            block.timestamp >= terms.maturityDate + EMERGENCY_GRACE_PERIOD,
            "Bond: grace period not expired"
        );
        require(proposedEmergencyRedemptionRate == 0, "Bond: proposal already pending");
        proposedEmergencyRedemptionRate = rate;
        proposedEmergencyRedemptionTimestamp = block.timestamp + EMERGENCY_REDEMPTION_DELAY;
        emit EmergencyRedemptionProposed(rate, proposedEmergencyRedemptionTimestamp);
    }

    function executeEmergencyRedemptionRate()
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.MATURED)
    {
        require(redemptionRate == 0, "Bond: already repaid");
        uint256 rate = proposedEmergencyRedemptionRate;
        require(rate > 0, "Bond: no proposal pending");
        require(block.timestamp >= proposedEmergencyRedemptionTimestamp, "Bond: timelocked");
        redemptionRate = rate;
        proposedEmergencyRedemptionRate = 0;
        proposedEmergencyRedemptionTimestamp = 0;
        emit EmergencyRedemptionExecuted(rate);
    }

    function cancelEmergencyRedemptionRate() external onlyRole(ADMIN_ROLE) {
        uint256 cancelled = proposedEmergencyRedemptionRate;
        require(cancelled > 0, "Bond: no proposal pending");
        proposedEmergencyRedemptionRate = 0;
        proposedEmergencyRedemptionTimestamp = 0;
        emit EmergencyRedemptionCancelled(cancelled);
    }

    // ------- EARLY BUYBACK ---------------------------------------------------

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

    function redeemEarly(uint256 bondAmount) external nonReentrant onlyState(State.ACTIVE) {
        require(earlyBuybackPool > 0,                "Bond: no buyback pool");
        require(bondAmount > 0,                      "Bond: zero amount");
        require(balanceOf(msg.sender) >= bondAmount, "Bond: insufficient bonds");

        uint256 payout = (bondAmount * earlyBuybackRate) / PRECISION;
        require(payout <= earlyBuybackPool,          "Bond: pool exhausted");

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

    // ------- INTERNAL --------------------------------------------------------

    function _accrueCoupon(address account) internal {
        uint256 checkpoint = _couponCheckpoint[account];
        if (totalCouponPerToken > checkpoint) {
            uint256 earned = (balanceOf(account) * (totalCouponPerToken - checkpoint)) / PRECISION;
            _pendingCoupons[account] += earned;
            _couponCheckpoint[account] = totalCouponPerToken;
        }
    }

    // ------- VIEWS -----------------------------------------------------------

    function expectedCouponAmount() public view returns (uint256) {
        return (couponEligibleSupply * terms.faceValue * terms.couponRate * terms.couponFrequency)
            / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
    }

    function expectedBulletRepayment() public view returns (uint256) {
        if (issueDate == 0) return 0;
        uint256 principal = couponEligibleSupply * terms.faceValue;
        uint256 duration  = terms.maturityDate - issueDate;
        uint256 interest  = (principal * terms.couponRate * duration)
            / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
        return principal + interest;
    }

    /// @notice S-01 : amount of the final stub coupon, post-maturity.
    function expectedFinalCouponAmount() external view returns (uint256) {
        if (terms.paymentMode != PaymentMode.COUPON) return 0;
        if (finalCouponPaid) return 0;
        if (block.timestamp < terms.maturityDate) return 0;

        uint256 lastCouponDate = couponsPaid == 0
            ? issueDate
            : nextCouponDate - terms.couponFrequency;
        if (terms.maturityDate <= lastCouponDate) return 0;

        uint256 stubPeriod = terms.maturityDate - lastCouponDate;
        return (couponEligibleSupply * terms.faceValue * terms.couponRate * stubPeriod)
            / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
    }

    function pendingCoupons(address account) external view returns (uint256) {
        uint256 checkpoint = _couponCheckpoint[account];
        uint256 accruing   = 0;
        if (totalCouponPerToken > checkpoint) {
            accruing = (balanceOf(account) * (totalCouponPerToken - checkpoint)) / PRECISION;
        }
        return _pendingCoupons[account] + accruing;
    }

    function getTerms() external view returns (BondTerms memory) { return terms; }
    function totalRaised() external view returns (uint256) { return totalPaymentReceived; }

    /// @notice S-02 : remaining cap that AGENT_ROLE can mint in the current 24h window.
    function remainingAgentMintCap() external view returns (uint256) {
        if (state != State.ACTIVE) return type(uint256).max;
        uint256 cap = (terms.totalIssuance * AGENT_MINT_CAP_BPS) / BPS_DENOMINATOR;
        if (block.timestamp >= _agentMintWindowStart + 1 days) return cap;
        if (_agentMintInWindow >= cap) return 0;
        return cap - _agentMintInWindow;
    }

    // ------- ERC-3643 token API ----------------------------------------------

    function version() external pure override returns (string memory) { return TOKEN_VERSION; }
    function onchainID() external view override returns (address) { return _tokenOnchainID; }
    function identityRegistry() external view override returns (IIdentityRegistry) { return _identityRegistry; }
    function compliance() external view override returns (ICompliance) { return _tokenCompliance; }
    function isFrozen(address userAddress) external view override returns (bool) { return _frozen[userAddress]; }
    function getFrozenTokens(address userAddress) external view override returns (uint256) { return _frozenTokens[userAddress]; }

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

    /// @notice S-02 : agent mint capped at AGENT_MINT_CAP_BPS of totalIssuance per 24h.
    function mint(address to, uint256 amount) public override onlyRole(AGENT_ROLE) {
        require(
            state == State.SUBSCRIPTION || state == State.ACTIVE,
            "Bond: mint only allowed during subscription or active"
        );
        if (state == State.ACTIVE) {
            if (block.timestamp >= _agentMintWindowStart + 1 days) {
                _agentMintWindowStart = block.timestamp;
                _agentMintInWindow = 0;
            }
            uint256 cap = (terms.totalIssuance * AGENT_MINT_CAP_BPS) / BPS_DENOMINATOR;
            require(_agentMintInWindow + amount <= cap, "Bond: agent mint cap exceeded");
            _agentMintInWindow += amount;
            emit AgentMintCapWindow(_agentMintWindowStart, _agentMintInWindow, cap);
        }
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
            emit IdentityRecoveryFallback(newWallet, "registerIdentity");
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
        try _identityRegistry.deleteIdentity(lostWallet) {} catch {
            emit IdentityRecoveryFallback(lostWallet, "deleteIdentity");
        }
        emit RecoverySuccess(lostWallet, newWallet, investorOnchainID);
        return true;
    }

    function batchTransfer(address[] calldata toList, uint256[] calldata amounts) external override {
        uint256 len = toList.length;
        require(len == amounts.length, "Bond: length mismatch");
        require(len <= MAX_BATCH_SIZE,  "Bond: batch too large");
        for (uint256 i = 0; i < len;) {
            transfer(toList[i], amounts[i]);
            unchecked { ++i; }
        }
    }

    function batchForcedTransfer(
        address[] calldata fromList,
        address[] calldata toList,
        uint256[] calldata amounts
    ) external override {
        uint256 len = fromList.length;
        require(len == toList.length && len == amounts.length, "Bond: length mismatch");
        require(len <= MAX_BATCH_SIZE, "Bond: batch too large");
        for (uint256 i = 0; i < len;) {
            forcedTransfer(fromList[i], toList[i], amounts[i]);
            unchecked { ++i; }
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

    // ------- PAUSE + UPGRADE TIMELOCK ----------------------------------------

    function pause() external override onlyRole(AGENT_ROLE) { _pause(); }
    function unpause() external override onlyRole(AGENT_ROLE) { _unpause(); }

    /// @notice S-04 : propose a new implementation. Execution timelock 7 days.
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

    /// @dev S-05 : initialize-only path. Bond does NOT bind itself; BondFactory does.
    function _setComplianceInitial(address newCompliance) internal {
        require(newCompliance != address(0), "Bond: zero compliance");
        _tokenCompliance = ICompliance(newCompliance);
        emit ComplianceAdded(newCompliance);
    }

    /// @dev S-05 : post-init switch. Requires the new compliance to already declare
    ///      this token bound. Admin must orchestrate the bind in a separate tx.
    function _setCompliance(address newCompliance) internal {
        require(newCompliance != address(0), "Bond: zero compliance");
        if (address(_tokenCompliance) != address(0)) {
            try _tokenCompliance.unbindToken(address(this)) {} catch {}
        }
        require(
            ICompliance(newCompliance).isTokenBound(address(this)),
            "Bond: not bound on new compliance"
        );
        _tokenCompliance = ICompliance(newCompliance);
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
