// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IGlobalIdentityRegistry} from "./IGlobalIdentityRegistry.sol";

/// @title Per-product eligibility registry.
/// @notice Sits on top of `IGlobalIdentityRegistry` to encode per-product
///         restrictions: minimum KYC level, allowed countries (whitelist),
///         blocked countries (override), manual account allow/block lists.
///
/// @dev Eligibility decision algorithm for `isEligible(productId, user)`:
///
///         1. config = configOf(productId)
///         2. if config.status == Frozen                            -> false
///         3. if accountBlocklist[productId][user]                  -> false
///         4. if accountAllowlist[productId][user]                  -> true
///         5. id = identityRegistry.identityOf(user)
///         6. if id.status != Verified                              -> false
///         7. if id.expiresAt <= block.timestamp                    -> false
///         8. if id.level < config.minKycLevel                      -> false
///         9. if id.verifiedAt < config.minVerifiedAfter            -> false
///        10. if config.requireCountryAllowlist
///               && !allowedCountries[productId][id.country]        -> false
///        11. if blockedCountries[productId][id.country]            -> false
///        12.                                                          true
interface IProductEligibilityRegistry {
    enum ProductStatus {
        Inactive,        // 0 — not yet registered, no subscriptions or transfers
        Open,            // 1 — subscriptions and redemptions allowed
        RedemptionOnly,  // 2 — only redemptions allowed (sunset mode)
        Frozen           // 3 — no transfers (emergency)
    }

    struct ProductConfig {
        ProductStatus status;
        IGlobalIdentityRegistry.KycLevel minKycLevel;
        bool requireCountryAllowlist;
        uint64 minVerifiedAfter;
        address token; // the brvUSTY-like token address bound to this product
    }

    // ---------------- events ----------------

    event ProductRegistered(
        bytes32 indexed productId,
        address indexed token,
        IGlobalIdentityRegistry.KycLevel minKycLevel,
        bool requireCountryAllowlist
    );
    event ProductStatusUpdated(bytes32 indexed productId, ProductStatus oldStatus, ProductStatus newStatus);
    event ProductMinKycLevelUpdated(
        bytes32 indexed productId,
        IGlobalIdentityRegistry.KycLevel oldLevel,
        IGlobalIdentityRegistry.KycLevel newLevel
    );
    event ProductMinVerifiedAfterUpdated(bytes32 indexed productId, uint64 oldTs, uint64 newTs);
    event ProductCountryAllowlistToggled(bytes32 indexed productId, bool requireAllowlist);

    event CountryAllowed(bytes32 indexed productId, bytes2 country);
    event CountryDisallowed(bytes32 indexed productId, bytes2 country);
    event CountryBlocked(bytes32 indexed productId, bytes2 country);
    event CountryUnblocked(bytes32 indexed productId, bytes2 country);

    event AccountAllowlisted(bytes32 indexed productId, address indexed account);
    event AccountAllowlistRemoved(bytes32 indexed productId, address indexed account);
    event AccountBlocklisted(bytes32 indexed productId, address indexed account, bytes32 reason);
    event AccountBlocklistRemoved(bytes32 indexed productId, address indexed account);

    // ---------------- views ----------------

    function identityRegistry() external view returns (IGlobalIdentityRegistry);

    function productOf(address token) external view returns (bytes32);
    function configOf(bytes32 productId) external view returns (ProductConfig memory);

    function isEligible(bytes32 productId, address user) external view returns (bool);
    /// @notice Same as `isEligible` but also returns a machine-readable
    ///         reason on failure. Reason is a `bytes32` ASCII-like tag,
    ///         e.g. `bytes32("COUNTRY_NOT_ALLOWED")`.
    function checkEligibility(bytes32 productId, address user)
        external
        view
        returns (bool ok, bytes32 reason);

    function isCountryAllowed(bytes32 productId, bytes2 country) external view returns (bool);
    function isCountryBlocked(bytes32 productId, bytes2 country) external view returns (bool);
    function isAccountAllowlisted(bytes32 productId, address account) external view returns (bool);
    function isAccountBlocklisted(bytes32 productId, address account) external view returns (bool);

    // ---------------- mutating ----------------

    function registerProduct(
        bytes32 productId,
        address token,
        IGlobalIdentityRegistry.KycLevel minKycLevel,
        bool requireCountryAllowlist
    ) external;

    function setProductStatus(bytes32 productId, ProductStatus newStatus) external;
    function setMinKycLevel(bytes32 productId, IGlobalIdentityRegistry.KycLevel newLevel) external;
    function setMinVerifiedAfter(bytes32 productId, uint64 newTs) external;
    function setRequireCountryAllowlist(bytes32 productId, bool required) external;

    function allowCountry(bytes32 productId, bytes2 country) external;
    function disallowCountry(bytes32 productId, bytes2 country) external;
    function batchAllowCountries(bytes32 productId, bytes2[] calldata countries) external;

    function blockCountry(bytes32 productId, bytes2 country) external;
    function unblockCountry(bytes32 productId, bytes2 country) external;
    function batchBlockCountries(bytes32 productId, bytes2[] calldata countries) external;

    function addAllowlistAccount(bytes32 productId, address account) external;
    function removeAllowlistAccount(bytes32 productId, address account) external;
    function addBlocklistAccount(bytes32 productId, address account, bytes32 reason) external;
    function removeBlocklistAccount(bytes32 productId, address account) external;
}
