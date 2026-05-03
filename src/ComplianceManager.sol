// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ComplianceManager
 * @notice Registre de conformité KYC/AML pour la plateforme Bondary.
 *         Inspiré ERC-3643 : whitelist investisseurs + blacklist AML individuelle.
 *
 *         Un compte est "vérifié" (isVerified) si :
 *           - il est dans la whitelist KYC (identité validée)
 *           - ET il n'est PAS dans la blacklist AML (pas de flag de suspicion)
 *
 *         Les obligations corporate (CorporateBond) appellent isVerified()
 *         avant chaque transfert de token. Architecture compatible avec une
 *         future migration vers ERC-3643 complet.
 */
contract ComplianceManager is AccessControl {
    bytes32 public constant KYC_OPERATOR_ROLE    = keccak256("KYC_OPERATOR_ROLE");
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");

    mapping(address => bool) private _whitelisted;
    mapping(address => bool) private _blacklisted;

    event Whitelisted(address indexed account);
    event WhitelistRevoked(address indexed account);
    event Blacklisted(address indexed account, string reason);
    event Unblacklisted(address indexed account);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_OPERATOR_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
    }

    // ─── Whitelist KYC ────────────────────────────────────────────────────

    function whitelist(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _whitelisted[account] = true;
        emit Whitelisted(account);
    }

    function revoke(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _whitelisted[account] = false;
        emit WhitelistRevoked(account);
    }

    function batchWhitelist(address[] calldata accounts) external onlyRole(KYC_OPERATOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            _whitelisted[accounts[i]] = true;
            emit Whitelisted(accounts[i]);
        }
    }

    // ─── Blacklist AML ────────────────────────────────────────────────────

    function blacklist(address account, string calldata reason)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        _blacklisted[account] = true;
        emit Blacklisted(account, reason);
    }

    function unblacklist(address account) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    /**
     * @notice Renvoie true si le compte est KYC validé ET non blacklisté.
     *         C'est la fonction appelée avant chaque transfert de bond token.
     */
    function isVerified(address account) external view returns (bool) {
        return _whitelisted[account] && !_blacklisted[account];
    }

    function isWhitelisted(address account) external view returns (bool) {
        return _whitelisted[account];
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }
}
