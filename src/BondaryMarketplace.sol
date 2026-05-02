// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BondaryWhitelist} from "./BondaryWhitelist.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";
import {BondVaultFactory} from "./BondVaultFactory.sol";
import {BondVault} from "./BondVault.sol";

/**
 * @title BondaryMarketplace
 * @notice Marché secondaire peer-to-peer pour les parts de vaults Bondary.
 *
 *         Pourquoi un order book et non un AMM standard (Uniswap) ?
 *         Les parts de vault sont des security tokens : seules les adresses KYC
 *         peuvent les détenir. Un AMM public permettrait à n'importe qui d'acheter,
 *         ce qui violerait la réglementation MiFID II. Ici, chaque trade vérifie
 *         que l'acheteur est bien dans le whitelist Bondary.
 *
 *         Frais :
 *           - tradingFeeBps : prélevé sur chaque trade (revenu plateforme)
 *           - earlyExitPenaltyBps : prélevé en plus si le vault est encore ACTIVE
 *             (incite les investisseurs à rester jusqu'à maturité)
 *
 *         Prix :
 *           pricePerShare est exprimé en wei de l'asset par wei de part.
 *           totalCost = shares * pricePerShare / 10^shareDecimals
 */
contract BondaryMarketplace is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant MAX_FEE_BPS     = 1_000; // 10 % plafond
    uint256 public constant BPS_DENOMINATOR = 10_000;

    BondaryWhitelist    public immutable whitelist;
    BondaryFeeCollector public immutable feeCollector;
    BondVaultFactory    public immutable factory;

    uint256 public tradingFeeBps;        // ex: 50 = 0.50 %
    uint256 public earlyExitPenaltyBps;  // ex: 200 = 2.00 %

    uint256 private _nextOrderId;

    struct Order {
        address vault;          // Adresse du proxy BondVault
        address seller;         // Vendeur des parts
        uint256 shares;         // Quantité de parts à vendre (wei)
        uint256 pricePerShare;  // Prix par wei de part, exprimé en wei d'asset
        bool    active;
    }

    mapping(uint256 => Order) public orders;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event OrderCreated(
        uint256 indexed orderId,
        address indexed vault,
        address indexed seller,
        uint256 shares,
        uint256 pricePerShare
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 shares,
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
        address _whitelist,
        address _feeCollector,
        address _factory,
        uint256 _tradingFeeBps,
        uint256 _earlyExitPenaltyBps
    ) {
        require(_tradingFeeBps     <= MAX_FEE_BPS, "Marketplace: trading fee too high");
        require(_earlyExitPenaltyBps <= MAX_FEE_BPS, "Marketplace: penalty too high");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        whitelist    = BondaryWhitelist(_whitelist);
        feeCollector = BondaryFeeCollector(_feeCollector);
        factory      = BondVaultFactory(_factory);

        tradingFeeBps       = _tradingFeeBps;
        earlyExitPenaltyBps = _earlyExitPenaltyBps;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Order management
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Crée un ordre de vente. Les parts sont séquestrées dans ce contrat.
     * @param vault          Adresse du BondVault dont on vend les parts
     * @param shares         Nombre de parts à vendre (en wei)
     * @param pricePerShare  Prix par wei de part en wei d'asset
     *                       Ex : 1 part USDC-vault (6 dec) à 1.05 USDC
     *                            → pricePerShare = 1_050_000
     * @return orderId       Identifiant de l'ordre
     */
    function createSellOrder(
        address vault,
        uint256 shares,
        uint256 pricePerShare
    ) external nonReentrant whenNotPaused returns (uint256 orderId) {
        require(factory.isOfficialVault(vault),          "Marketplace: not official vault");
        require(whitelist.isWhitelisted(msg.sender),     "Marketplace: seller not KYC");
        require(shares > 0,                              "Marketplace: zero shares");
        require(pricePerShare > 0,                       "Marketplace: zero price");
        require(
            IERC20(vault).balanceOf(msg.sender) >= shares,
            "Marketplace: insufficient shares"
        );

        // Séquestre les parts dans ce contrat (ce contrat doit être whitelisté)
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        orderId = _nextOrderId++;
        orders[orderId] = Order({
            vault:         vault,
            seller:        msg.sender,
            shares:        shares,
            pricePerShare: pricePerShare,
            active:        true
        });

        emit OrderCreated(orderId, vault, msg.sender, shares, pricePerShare);
    }

    /**
     * @notice Exécute un ordre de vente.
     *         Vérifie le KYC de l'acheteur, prélève les frais, transfère les parts.
     * @param orderId  Identifiant de l'ordre à exécuter
     */
    function fillOrder(uint256 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        require(order.active,                            "Marketplace: order not active");
        require(whitelist.isWhitelisted(msg.sender),     "Marketplace: buyer not KYC");
        require(msg.sender != order.seller,              "Marketplace: self-trade");

        address vault      = order.vault;
        address assetToken = BondVault(vault).asset();
        uint8   shareDec   = IERC20Metadata(vault).decimals();

        // totalCost = shares * pricePerShare / 10^shareDecimals (en wei d'asset)
        uint256 totalCost = (order.shares * order.pricePerShare) / (10 ** shareDec);
        require(totalCost > 0, "Marketplace: zero cost");

        // Frais de trading (toujours appliqués)
        uint256 tradingFee = (totalCost * tradingFeeBps) / BPS_DENOMINATOR;

        // Pénalité de sortie anticipée si le vault est encore ACTIVE et non matured
        uint256 penaltyFee = 0;
        BondVault bv = BondVault(vault);
        if (bv.state() == BondVault.State.ACTIVE) {
            uint256 maturity = bv.loanMaturity();
            if (maturity > 0 && block.timestamp < maturity) {
                penaltyFee = (totalCost * earlyExitPenaltyBps) / BPS_DENOMINATOR;
            }
        }

        uint256 totalFees      = tradingFee + penaltyFee;
        uint256 sellerReceives = totalCost - totalFees;

        // Paiement : acheteur → vendeur (net de frais)
        IERC20(assetToken).safeTransferFrom(msg.sender, order.seller, sellerReceives);

        // Paiement : acheteur → FeeCollector (frais)
        if (totalFees > 0) {
            IERC20(assetToken).safeTransferFrom(msg.sender, address(feeCollector), totalFees);
            if (tradingFee > 0) {
                feeCollector.notifyFeeReceived(
                    assetToken, tradingFee, BondaryFeeCollector.FeeType.MARKETPLACE
                );
            }
            if (penaltyFee > 0) {
                feeCollector.notifyFeeReceived(
                    assetToken, penaltyFee, BondaryFeeCollector.FeeType.PENALTY
                );
            }
        }

        // Transfert des parts séquestrées → acheteur
        IERC20(vault).safeTransfer(msg.sender, order.shares);

        order.active = false;
        emit OrderFilled(orderId, msg.sender, order.shares, totalCost, tradingFee, penaltyFee);
    }

    /**
     * @notice Annule un ordre et restitue les parts au vendeur.
     *         Seul le vendeur ou un ADMIN peut annuler.
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.active, "Marketplace: order not active");
        require(
            order.seller == msg.sender || hasRole(ADMIN_ROLE, msg.sender),
            "Marketplace: not authorized"
        );

        IERC20(order.vault).safeTransfer(order.seller, order.shares);
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
        require(_tradingFeeBps     <= MAX_FEE_BPS, "Marketplace: trading fee too high");
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
