// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGlobalIdentityRegistry} from "../interfaces/IGlobalIdentityRegistry.sol";
import {TreasuryErrors} from "../libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../libraries/TreasuryRoles.sol";

/// @title Global identity registry — Brivo Treasury KYC layer.
/// @notice Holds per-user KYC status, level, country and expiry. Mutating
///         calls are restricted to `KYC_OPERATOR_ROLE`. Reads are public.
///         The registry is shared across all Brivo Treasury products
///         (brvUSTY, brvEURT, brvLUSD, ...). Per-product rules live in
///         `ProductEligibilityRegistry`.
/// @dev    Non-upgradeable. If the KYC schema must change, deploy a new
///         registry and re-point the eligibility registry.
contract GlobalIdentityRegistry is IGlobalIdentityRegistry, AccessControl {
    mapping(address => Identity) private _identities;

    constructor(address admin, address kycOperator) {
        if (admin == address(0) || kycOperator == address(0)) {
            revert TreasuryErrors.ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.KYC_OPERATOR_ROLE, kycOperator);
    }

    // ---------------- views ----------------

    function identityOf(address user) external view returns (Identity memory) {
        return _identities[user];
    }

    function isVerified(address user) external view returns (bool) {
        Identity storage id = _identities[user];
        return id.status == IdentityStatus.Verified && id.expiresAt > block.timestamp;
    }

    function kycLevelOf(address user) external view returns (KycLevel) {
        return _identities[user].level;
    }

    function countryOf(address user) external view returns (bytes2) {
        return _identities[user].country;
    }

    // ---------------- mutating — KYC operator ----------------

    function registerIdentity(
        address user,
        KycLevel level,
        bytes2 country,
        uint64 verifiedAt,
        uint64 expiresAt,
        bytes32 externalRef
    ) external onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE) {
        _registerIdentity(user, level, country, verifiedAt, expiresAt, externalRef);
    }

    function renewIdentity(
        address user,
        uint64 newVerifiedAt,
        uint64 newExpiresAt,
        bytes32 externalRef
    ) external onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE) {
        Identity storage id = _identities[user];
        if (id.status == IdentityStatus.None) revert TreasuryErrors.IdentityNotRegistered(user);
        if (id.status == IdentityStatus.Revoked) revert TreasuryErrors.IdentityRevoked(user);
        if (newExpiresAt <= newVerifiedAt) revert TreasuryErrors.InvalidKycLevel();

        id.verifiedAt = newVerifiedAt;
        id.expiresAt = newExpiresAt;
        id.externalRef = externalRef;
        if (id.status != IdentityStatus.Verified) {
            IdentityStatus old = id.status;
            id.status = IdentityStatus.Verified;
            emit IdentityUpdated(user, old, IdentityStatus.Verified, id.level, id.level, id.country);
        }
        emit IdentityRenewed(user, newVerifiedAt, newExpiresAt, externalRef);
    }

    function updateCountry(address user, bytes2 newCountry)
        external
        onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE)
    {
        if (newCountry == bytes2(0)) revert TreasuryErrors.InvalidCountry();
        Identity storage id = _identities[user];
        if (id.status == IdentityStatus.None) revert TreasuryErrors.IdentityNotRegistered(user);
        bytes2 oldCountry = id.country;
        id.country = newCountry;
        emit IdentityCountryChanged(user, oldCountry, newCountry);
    }

    function suspendIdentity(address user, bytes32 reason)
        external
        onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE)
    {
        Identity storage id = _identities[user];
        if (id.status == IdentityStatus.None) revert TreasuryErrors.IdentityNotRegistered(user);
        if (id.status == IdentityStatus.Revoked) revert TreasuryErrors.IdentityRevoked(user);
        IdentityStatus old = id.status;
        id.status = IdentityStatus.Suspended;
        emit IdentityUpdated(user, old, IdentityStatus.Suspended, id.level, id.level, id.country);
        emit IdentitySuspended(user, reason);
    }

    function unsuspendIdentity(address user)
        external
        onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE)
    {
        Identity storage id = _identities[user];
        if (id.status != IdentityStatus.Suspended) revert TreasuryErrors.IdentityNotVerified(user);
        id.status = IdentityStatus.Verified;
        emit IdentityUpdated(user, IdentityStatus.Suspended, IdentityStatus.Verified, id.level, id.level, id.country);
    }

    function revokeIdentity(address user, bytes32 reason)
        external
        onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE)
    {
        Identity storage id = _identities[user];
        if (id.status == IdentityStatus.None) revert TreasuryErrors.IdentityNotRegistered(user);
        IdentityStatus old = id.status;
        id.status = IdentityStatus.Revoked;
        emit IdentityUpdated(user, old, IdentityStatus.Revoked, id.level, id.level, id.country);
        emit IdentityRevoked(user, reason);
    }

    function batchRegister(
        address[] calldata users,
        KycLevel[] calldata levels,
        bytes2[] calldata countries,
        uint64[] calldata verifiedAts,
        uint64[] calldata expiresAts,
        bytes32[] calldata externalRefs
    ) external onlyRole(TreasuryRoles.KYC_OPERATOR_ROLE) {
        uint256 len = users.length;
        if (
            levels.length != len ||
            countries.length != len ||
            verifiedAts.length != len ||
            expiresAts.length != len ||
            externalRefs.length != len
        ) revert TreasuryErrors.LengthMismatch();

        for (uint256 i; i < len; ++i) {
            _registerIdentity(
                users[i],
                levels[i],
                countries[i],
                verifiedAts[i],
                expiresAts[i],
                externalRefs[i]
            );
        }
    }

    // ---------------- internal ----------------

    function _registerIdentity(
        address user,
        KycLevel level,
        bytes2 country,
        uint64 verifiedAt,
        uint64 expiresAt,
        bytes32 externalRef
    ) internal {
        if (user == address(0)) revert TreasuryErrors.ZeroAddress();
        if (level == KycLevel.None) revert TreasuryErrors.InvalidKycLevel();
        if (country == bytes2(0)) revert TreasuryErrors.InvalidCountry();
        if (expiresAt <= verifiedAt) revert TreasuryErrors.InvalidKycLevel();

        Identity storage id = _identities[user];
        if (id.status == IdentityStatus.Revoked) revert TreasuryErrors.IdentityRevoked(user);

        IdentityStatus oldStatus = id.status;
        KycLevel oldLevel = id.level;

        id.status = IdentityStatus.Verified;
        id.level = level;
        id.country = country;
        id.verifiedAt = verifiedAt;
        id.expiresAt = expiresAt;
        id.externalRef = externalRef;

        if (oldStatus == IdentityStatus.None) {
            emit IdentityRegistered(user, level, country, verifiedAt, expiresAt, externalRef);
        } else {
            emit IdentityUpdated(user, oldStatus, IdentityStatus.Verified, oldLevel, level, country);
        }
    }
}
