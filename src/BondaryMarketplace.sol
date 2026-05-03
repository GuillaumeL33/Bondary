// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ComplianceManager} from "./ComplianceManager.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";
import {BondFactory} from "./BondFactory.sol";
import {CorporateBond} from "./CorporateBond.sol";

/**
 * @title BondaryMarketplace
 * @notice Marché secondaire peer-to-peer pour les obligations corporate Bondary.
 *
 *         Pourquoi un order book et non un AMM standard (Uniswap) ?
 *         Les bonds sont des security tokens (MiFID II) : seules les adresses KYC
 *         validées peuvent les détenir. Un AMM public permettrait à n'importe qui
 *         d'acheter, violant la réglementation. Ici, chaque trade vérifie que
 *         l'acheteur est isVerified() dans ComplianceManager.
 *
 *         Tarification :
 *           pricePerBond est exprimé en wei du token de paiement par bond entier.
 *           Les bonds ont 0 décimales, donc : totalCost = bonds × pricePerBond.
 *
 *         Frais :
 *           tradingFeeBps       : prélevé sur chaque trade (revenu plateforme)
 *           earlyExitPenaltyBps : prélevé en plus si le bond est en état ACTIVE
 *                                 (incite les investisseurs à rester jusqu'à maturité)
 */
contract BondaryMarketplace is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant MAX_FEE_BPS     = 1_000; // 10% plafond
    uint256 public constant BPS_DENOMINATOR = 10_000;

    ComplianceManager   public immutable compliance;
    BondaryFeeCollector public immutable feeCollector;
    BondFactory         public immutable factory;

    uint256 public tradingFeeBps;        // ex: 50 = 0.50%
    uint256 public earlyExitPenaltyBps;  // ex: 200 = 2.00%

    uint256 private _nextOrderId;

    struct Order {
        address bond;          // Adresse du proxy CorporateBond
        address seller;        // Vendeur des bonds
        uint256 bondAmount;    // Nombre de bonds entiers à vendre
        uint256 pricePerBond;  // Prix en wei du payment token par bond entier
        bool    active;
    }

    mapping(uint256 => Order) public orders;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event OrderCreated(
        uint256 indexed orderId,
        address indexed bond,
        address indexed seller,
        uint256 bondAmount,
        uint256 pricePerBond
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 bondAmount,
        uint256 totalCost,
        uint256 tradingFee,
        uint256 penaltyFee
    );
    event OrderCancelled(uint256 indexed orderId);
    event FeesUpdated(uint256 tradingFeeBps, uint256 earlyExitPenaltyBps);

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address admin,
        address _compliance,
        address _feeCollector,
        address _factory,
        uint256 _tradingFeeBps,
        uint256 _earlyExitPenaltyBps
    ) {
        require(_tradingFeeBps       <= MAX_FEE_BPS, "Marketplace: trading fee too high");
        require(_earlyExitPenaltyBps <= MAX_FEE_BPS, "Marketplace: penalty too high");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE,         admin);

        compliance   = ComplianceManager(_compliance);
        feeCollector = BondaryFeeCollector(_feeCollector);
        factory      = BondFactory(_factory);

        tradingFeeBps       = _tradingFeeBps;
        earlyExitPenaltyBps = _earlyExitPenaltyBps;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Order management
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Crée un ordre de vente. Les bonds sont séquestrés dans ce contrat.
     * @param bond          Adresse du CorporateBond dont on vend les bonds
     * @param bondAmount    Nombre de bonds entiers à vendre
     * @param pricePerBond  Prix en wei du payment token par bond entier
     *                      Ex : bond USDC à 1020 USDC → pricePerBond = 1020e6
     * @return orderId      Identifiant de l'ordre
     */
    function createSellOrder(
        address bond,
        uint256 bondAmount,
        uint256 pricePerBond
    ) external nonReentrant whenNotPaused returns (uint256 orderId) {
        require(factory.isOfficialBond(bond),         "Marketplace: not official bond");
        require(compliance.isVerified(msg.sender),    "Marketplace: seller not compliant");
        require(bondAmount > 0,                       "Marketplace: zero amount");
        require(pricePerBond > 0,                     "Marketplace: zero price");
        require(
            IERC20(bond).balanceOf(msg.sender) >= bondAmount,
            "Marketplace: insufficient bonds"
        );

        // Séquestre les bonds dans ce contrat
        // Ce contrat doit être isVerified() dans ComplianceManager
        IERC20(bond).safeTransferFrom(msg.sender, address(this), bondAmount);

        orderId = _nextOrderId++;
        orders[orderId] = Order({
            bond:         bond,
            seller:       msg.sender,
            bondAmount:   bondAmount,
            pricePerBond: pricePerBond,
            active:       true
        });

        emit OrderCreated(orderId, bond, msg.sender, bondAmount, pricePerBond);
    }

    /**
     * @notice Exécute un ordre de vente.
     *         Vérifie la conformité KYC/AML de l'acheteur, prélève les frais,
     *         transfère les bonds.
     * @param orderId  Identifiant de l'ordre à exécuter
     */
    function fillOrder(uint256 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        require(order.active,                          "Marketplace: order not active");
        require(compliance.isVerified(msg.sender),     "Marketplace: buyer not compliant");
        require(msg.sender != order.seller,            "Marketplace: self-trade");

        CorporateBond cb = CorporateBond(order.bond);
        address paymentToken = cb.getTerms().paymentToken;

        // totalCost = bondAmount × pricePerBond (bonds ont 0 décimales)
        uint256 totalCost = order.bondAmount * order.pricePerBond;
        require(totalCost > 0, "Marketplace: zero cost");

        // Frais de trading (toujours appliqués)
        uint256 tradingFee = (totalCost * tradingFeeBps) / BPS_DENOMINATOR;

        // Pénalité de sortie anticipée si le bond est encore ACTIVE (avant maturité)
        uint256 penaltyFee = 0;
        if (cb.state() == CorporateBond.State.ACTIVE) {
            penaltyFee = (totalCost * earlyExitPenaltyBps) / BPS_DENOMINATOR;
        }

        uint256 totalFees      = tradingFee + penaltyFee;
        uint256 sellerReceives = totalCost - totalFees;

        // Paiement acheteur → vendeur (net de frais)
        IERC20(paymentToken).safeTransferFrom(msg.sender, order.seller, sellerReceives);

        // Paiement acheteur → FeeCollector
        if (totalFees > 0) {
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(feeCollector), totalFees);
            if (tradingFee > 0) {
                feeCollector.notifyFeeReceived(
                    paymentToken, tradingFee, BondaryFeeCollector.FeeType.MARKETPLACE
                );
            }
            if (penaltyFee > 0) {
                feeCollector.notifyFeeReceived(
                    paymentToken, penaltyFee, BondaryFeeCollector.FeeType.PENALTY
                );
            }
        }

        // Transfert des bonds séquestrés → acheteur
        IERC20(order.bond).safeTransfer(msg.sender, order.bondAmount);

        order.active = false;
        emit OrderFilled(orderId, msg.sender, order.bondAmount, totalCost, tradingFee, penaltyFee);
    }

    /**
     * @notice Annule un ordre et restitue les bonds au vendeur.
     *         Seul le vendeur ou un ADMIN peut annuler.
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.active, "Marketplace: order not active");
        require(
            order.seller == msg.sender || hasRole(ADMIN_ROLE, msg.sender),
            "Marketplace: not authorized"
        );

        IERC20(order.bond).safeTransfer(order.seller, order.bondAmount);
        order.active = false;
        emit OrderCancelled(orderId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────────────────

    function updateFees(uint256 _tradingFeeBps, uint256 _earlyExitPenaltyBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(_tradingFeeBps       <= MAX_FEE_BPS, "Marketplace: trading fee too high");
        require(_earlyExitPenaltyBps <= MAX_FEE_BPS, "Marketplace: penalty too high");
        tradingFeeBps       = _tradingFeeBps;
        earlyExitPenaltyBps = _earlyExitPenaltyBps;
        emit FeesUpdated(_tradingFeeBps, _earlyExitPenaltyBps);
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────────

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function nextOrderId() external view returns (uint256) {
        return _nextOrderId;
    }
}
