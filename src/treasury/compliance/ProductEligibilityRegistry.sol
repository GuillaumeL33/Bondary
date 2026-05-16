// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGlobalIdentityRegistry} from "../interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../interfaces/IProductEligibilityRegistry.sol";
import {TreasuryErrors} from "../libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../libraries/TreasuryRoles.sol";

/// @title Per-product eligibility registry.
/// @notice Layered on top of `GlobalIdentityRegistry`. Enforces per-product
///         restrictions (min KYC level, allowed/blocked countries, account
///         allow/block lists). Read API is consumed by `BrivoVault._update`
///         on every transfer.
contract ProductEligibilityRegistry is IProductEligibilityRegistry, AccessControl {
    /// @notice ASCII-like rejection reasons returned by `checkEligibility`.
    bytes32 internal constant REASON_PRODUCT_INACTIVE   = bytes32("PRODUCT_INACTIVE");
    bytes32 internal constant REASON_PRODUCT_FROZEN     = bytes32("PRODUCT_FROZEN");
    bytes32 internal constant REASON_ACCOUNT_BLOCKED    = bytes32("ACCOUNT_BLOCKED");
    bytes32 internal constant REASON_KYC_MISSING        = bytes32("KYC_MISSING");
    bytes32 internal constant REASON_KYC_NOT_VERIFIED   = bytes32("KYC_NOT_VERIFIED");
    bytes32 internal constant REASON_KYC_EXPIRED        = bytes32("KYC_EXPIRED");
    bytes32 internal constant REASON_KYC_LEVEL_LOW      = bytes32("KYC_LEVEL_LOW");
    bytes32 internal constant REASON_KYC_STALE          = bytes32("KYC_STALE");
    bytes32 internal constant REASON_COUNTRY_NOT_ALLOW  = bytes32("COUNTRY_NOT_ALLOWED");
    bytes32 internal constant REASON_COUNTRY_BLOCKED    = bytes32("COUNTRY_BLOCKED");

    IGlobalIdentityRegistry public immutable identityRegistry;

    mapping(bytes32 productId => ProductConfig) private _configs;
    mapping(address token => bytes32 productId) private _productOf;

    mapping(bytes32 productId => mapping(bytes2 country => bool)) private _allowedCountries;
    mapping(bytes32 productId => mapping(bytes2 country => bool)) private _blockedCountries;
    mapping(bytes32 productId => mapping(address account => bool)) private _accountAllowlist;
    mapping(bytes32 productId => mapping(address account => bool)) private _accountBlocklist;

    constructor(address admin, IGlobalIdentityRegistry _identityRegistry, address productAdmin) {
        if (admin == address(0) || address(_identityRegistry) == address(0) || productAdmin == address(0)) {
            revert TreasuryErrors.ZeroAddress();
        }
        identityRegistry = _identityRegistry;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.PRODUCT_ADMIN_ROLE, productAdmin);
    }

    // ---------------- views ----------------

    function productOf(address token) external view returns (bytes32) {
        return _productOf[token];
    }

    function configOf(bytes32 productId) external view returns (ProductConfig memory) {
        return _configs[productId];
    }

    function isCountryAllowed(bytes32 productId, bytes2 country) external view returns (bool) {
        return _allowedCountries[productId][country];
    }

    function isCountryBlocked(bytes32 productId, bytes2 country) external view returns (bool) {
        return _blockedCountries[productId][country];
    }

    function isAccountAllowlisted(bytes32 productId, address account) external view returns (bool) {
        return _accountAllowlist[productId][account];
    }

    function isAccountBlocklisted(bytes32 productId, address account) external view returns (bool) {
        return _accountBlocklist[productId][account];
    }

    function isEligible(bytes32 productId, address user) external view returns (bool ok) {
        (ok, ) = _check(productId, user);
    }

    function checkEligibility(bytes32 productId, address user)
        external
        view
        returns (bool ok, bytes32 reason)
    {
        return _check(productId, user);
    }

    function _check(bytes32 productId, address user) internal view returns (bool, bytes32) {
        ProductConfig storage cfg = _configs[productId];
        if (cfg.status == ProductStatus.Inactive) return (false, REASON_PRODUCT_INACTIVE);
        if (cfg.status == ProductStatus.Frozen)   return (false, REASON_PRODUCT_FROZEN);

        if (_accountBlocklist[productId][user]) return (false, REASON_ACCOUNT_BLOCKED);
        if (_accountAllowlist[productId][user]) return (true, bytes32(0));

        IGlobalIdentityRegistry.Identity memory id = identityRegistry.identityOf(user);
        if (id.status == IGlobalIdentityRegistry.IdentityStatus.None) {
            return (false, REASON_KYC_MISSING);
        }
        if (id.status != IGlobalIdentityRegistry.IdentityStatus.Verified) {
            return (false, REASON_KYC_NOT_VERIFIED);
        }
        if (id.expiresAt <= block.timestamp) {
            return (false, REASON_KYC_EXPIRED);
        }
        if (uint8(id.level) < uint8(cfg.minKycLevel)) {
            return (false, REASON_KYC_LEVEL_LOW);
        }
        if (id.verifiedAt < cfg.minVerifiedAfter) {
            return (false, REASON_KYC_STALE);
        }
        if (_blockedCountries[productId][id.country]) {
            return (false, REASON_COUNTRY_BLOCKED);
        }
        if (cfg.requireCountryAllowlist && !_allowedCountries[productId][id.country]) {
            return (false, REASON_COUNTRY_NOT_ALLOW);
        }
        return (true, bytes32(0));
    }

    // ---------------- mutating — product admin ----------------

    function registerProduct(
        bytes32 productId,
        address token,
        IGlobalIdentityRegistry.KycLevel minKycLevel,
        bool requireCountryAllowlist
    ) external onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE) {
        if (productId == bytes32(0)) revert TreasuryErrors.ProductNotRegistered(productId);
        if (token == address(0)) revert TreasuryErrors.ZeroAddress();
        if (_configs[productId].status != ProductStatus.Inactive) {
            revert TreasuryErrors.ProductAlreadyRegistered(productId);
        }
        if (_productOf[token] != bytes32(0)) revert TreasuryErrors.TokenAlreadyMapped(token);

        _configs[productId] = ProductConfig({
            status: ProductStatus.Open,
            minKycLevel: minKycLevel,
            requireCountryAllowlist: requireCountryAllowlist,
            minVerifiedAfter: 0,
            token: token
        });
        _productOf[token] = productId;
        emit ProductRegistered(productId, token, minKycLevel, requireCountryAllowlist);
    }

    function setProductStatus(bytes32 productId, ProductStatus newStatus)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        ProductStatus old = _configs[productId].status;
        _configs[productId].status = newStatus;
        emit ProductStatusUpdated(productId, old, newStatus);
    }

    function setMinKycLevel(bytes32 productId, IGlobalIdentityRegistry.KycLevel newLevel)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        IGlobalIdentityRegistry.KycLevel old = _configs[productId].minKycLevel;
        _configs[productId].minKycLevel = newLevel;
        emit ProductMinKycLevelUpdated(productId, old, newLevel);
    }

    function setMinVerifiedAfter(bytes32 productId, uint64 newTs)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        uint64 old = _configs[productId].minVerifiedAfter;
        _configs[productId].minVerifiedAfter = newTs;
        emit ProductMinVerifiedAfterUpdated(productId, old, newTs);
    }

    function setRequireCountryAllowlist(bytes32 productId, bool required)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        _configs[productId].requireCountryAllowlist = required;
        emit ProductCountryAllowlistToggled(productId, required);
    }

    function allowCountry(bytes32 productId, bytes2 country)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        if (country == bytes2(0)) revert TreasuryErrors.InvalidCountry();
        _allowedCountries[productId][country] = true;
        emit CountryAllowed(productId, country);
    }

    function disallowCountry(bytes32 productId, bytes2 country)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        _allowedCountries[productId][country] = false;
        emit CountryDisallowed(productId, country);
    }

    function batchAllowCountries(bytes32 productId, bytes2[] calldata countries)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        for (uint256 i; i < countries.length; ++i) {
            bytes2 c = countries[i];
            if (c == bytes2(0)) revert TreasuryErrors.InvalidCountry();
            _allowedCountries[productId][c] = true;
            emit CountryAllowed(productId, c);
        }
    }

    function blockCountry(bytes32 productId, bytes2 country)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        if (country == bytes2(0)) revert TreasuryErrors.InvalidCountry();
        _blockedCountries[productId][country] = true;
        emit CountryBlocked(productId, country);
    }

    function unblockCountry(bytes32 productId, bytes2 country)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        _blockedCountries[productId][country] = false;
        emit CountryUnblocked(productId, country);
    }

    function batchBlockCountries(bytes32 productId, bytes2[] calldata countries)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        for (uint256 i; i < countries.length; ++i) {
            bytes2 c = countries[i];
            if (c == bytes2(0)) revert TreasuryErrors.InvalidCountry();
            _blockedCountries[productId][c] = true;
            emit CountryBlocked(productId, c);
        }
    }

    function addAllowlistAccount(bytes32 productId, address account)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        if (account == address(0)) revert TreasuryErrors.ZeroAddress();
        _accountAllowlist[productId][account] = true;
        emit AccountAllowlisted(productId, account);
    }

    function removeAllowlistAccount(bytes32 productId, address account)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        _accountAllowlist[productId][account] = false;
        emit AccountAllowlistRemoved(productId, account);
    }

    function addBlocklistAccount(bytes32 productId, address account, bytes32 reason)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        if (account == address(0)) revert TreasuryErrors.ZeroAddress();
        _accountBlocklist[productId][account] = true;
        emit AccountBlocklisted(productId, account, reason);
    }

    function removeBlocklistAccount(bytes32 productId, address account)
        external
        onlyRole(TreasuryRoles.PRODUCT_ADMIN_ROLE)
    {
        _requireProduct(productId);
        _accountBlocklist[productId][account] = false;
        emit AccountBlocklistRemoved(productId, account);
    }

    // ---------------- internal ----------------

    function _requireProduct(bytes32 productId) internal view {
        if (_configs[productId].token == address(0)) {
            revert TreasuryErrors.ProductNotRegistered(productId);
        }
    }
}
