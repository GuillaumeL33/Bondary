// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BondaryFeeCollector
 * @notice Centralise les revenus de la plateforme Bondary :
 *         - Frais de dossier (SETUP)       : % du montant levé à l'activation
 *         - Frais sur coupons (COUPON)     : % de chaque coupon versé
 *         - Frais sur remboursement (REDEMPTION) : % des intérêts bullet
 *         - Frais AMM (MARKETPLACE)        : % de chaque trade secondaire
 *         - Pénalités de sortie (PENALTY)  : sortie anticipée sur le marketplace
 *
 *         Contrôle d'accès :
 *           AUTHORIZED_SOURCE_ROLE : seuls les bonds et le marketplace officiels
 *             peuvent appeler notifyFeeReceived(). Empêche la falsification
 *             d'événements FeeReceived par des adresses arbitraires.
 *           WITHDRAWAL_ROLE : Gnosis Safe Bondary uniquement.
 */
contract BondaryFeeCollector is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant WITHDRAWAL_ROLE        = keccak256("WITHDRAWAL_ROLE");
    bytes32 public constant AUTHORIZED_SOURCE_ROLE = keccak256("AUTHORIZED_SOURCE_ROLE");

    enum FeeType {
        SETUP,
        COUPON,
        REDEMPTION,
        MARKETPLACE,
        PENALTY
    }

    event FeeReceived(address indexed source, address indexed token, uint256 amount, FeeType feeType);
    event FeeWithdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address admin) {
        require(admin != address(0), "FeeCollector: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WITHDRAWAL_ROLE, admin);
    }

    /**
     * @notice Appelé par les bonds/marketplace après transfert des tokens vers ce contrat.
     *         Restreint à AUTHORIZED_SOURCE_ROLE pour éviter la falsification d'événements.
     *         Accorder ce rôle aux bonds via BondFactory.createBond() et au marketplace
     *         dans le script de déploiement.
     */
    function notifyFeeReceived(address token, uint256 amount, FeeType feeType)
        external
        onlyRole(AUTHORIZED_SOURCE_ROLE)
    {
        require(token != address(0), "FeeCollector: zero token");
        require(amount > 0, "FeeCollector: zero amount");
        emit FeeReceived(msg.sender, token, amount, feeType);
    }

    function withdraw(address token, address to, uint256 amount)
        external
        onlyRole(WITHDRAWAL_ROLE)
    {
        require(token != address(0), "FeeCollector: zero token");
        require(to != address(0), "FeeCollector: zero recipient");
        require(amount > 0, "FeeCollector: zero amount");
        IERC20(token).safeTransfer(to, amount);
        emit FeeWithdrawn(token, to, amount);
    }

    function balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
