// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title BondaryWhitelist
 * @notice KYC registry partagé par tous les vaults Bondary.
 *         Une adresse validée ici peut interagir avec l'ensemble de la plateforme.
 *         La vérification KYC réelle se fait off-chain ; l'opérateur soumet
 *         la transaction on-chain après validation.
 */
contract BondaryWhitelist is AccessControl {
    bytes32 public constant KYC_OPERATOR_ROLE = keccak256("KYC_OPERATOR_ROLE");

    mapping(address => bool) private _whitelisted;

    event Whitelisted(address indexed account);
    event Revoked(address indexed account);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_OPERATOR_ROLE, admin);
    }

    function whitelist(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _whitelisted[account] = true;
        emit Whitelisted(account);
    }

    function revoke(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _whitelisted[account] = false;
        emit Revoked(account);
    }

    function batchWhitelist(address[] calldata accounts) external onlyRole(KYC_OPERATOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            _whitelisted[accounts[i]] = true;
            emit Whitelisted(accounts[i]);
        }
    }

    function isWhitelisted(address account) external view returns (bool) {
        return _whitelisted[account];
    }
}
