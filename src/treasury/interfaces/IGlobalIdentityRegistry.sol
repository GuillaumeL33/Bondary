// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Global identity registry for Brivo Treasury products.
/// @notice Stores the KYC/AML status, level and country of each user. The
///         registry is per-user and shared across all Treasury products.
///         A product-level eligibility layer
///         (`IProductEligibilityRegistry`) sits on top to enforce per-
///         product rules (min KYC level, allowed countries, etc.).
interface IGlobalIdentityRegistry {
    /// @dev Status order matters: only `Verified` allows transfers.
    enum IdentityStatus {
        None,        // 0 — no record
        Pending,     // 1 — KYC initiated, awaiting verification
        Verified,    // 2 — KYC completed, identity active
        Suspended,   // 3 — temporarily blocked (e.g. ongoing review)
        Revoked      // 4 — permanently blocked
    }

    /// @dev Level order matters: higher level satisfies lower-level checks.
    enum KycLevel {
        None,        // 0
        Basic,       // 1 — light KYC (retail, low ticket)
        Full,        // 2 — full KYC (standard ticket)
        Enhanced     // 3 — enhanced due diligence (institutional / high ticket)
    }

    struct Identity {
        IdentityStatus status;
        KycLevel level;
        bytes2 country;         // ISO-3166-1 alpha-2 ("FR", "DE", ...)
        uint64 verifiedAt;      // unix timestamp of last verification
        uint64 expiresAt;       // unix timestamp after which renewal is required
        bytes32 externalRef;    // hash of off-chain KYC file reference
    }

    // ---------------- events ----------------

    event IdentityRegistered(
        address indexed user,
        KycLevel level,
        bytes2 country,
        uint64 verifiedAt,
        uint64 expiresAt,
        bytes32 externalRef
    );
    event IdentityUpdated(
        address indexed user,
        IdentityStatus oldStatus,
        IdentityStatus newStatus,
        KycLevel oldLevel,
        KycLevel newLevel,
        bytes2 country
    );
    event IdentityRenewed(
        address indexed user,
        uint64 newVerifiedAt,
        uint64 newExpiresAt,
        bytes32 externalRef
    );
    event IdentitySuspended(address indexed user, bytes32 reason);
    event IdentityRevoked(address indexed user, bytes32 reason);
    event IdentityCountryChanged(address indexed user, bytes2 oldCountry, bytes2 newCountry);

    // ---------------- views ----------------

    function identityOf(address user) external view returns (Identity memory);
    function isVerified(address user) external view returns (bool);
    function kycLevelOf(address user) external view returns (KycLevel);
    function countryOf(address user) external view returns (bytes2);

    // ---------------- mutating ----------------

    function registerIdentity(
        address user,
        KycLevel level,
        bytes2 country,
        uint64 verifiedAt,
        uint64 expiresAt,
        bytes32 externalRef
    ) external;

    function renewIdentity(
        address user,
        uint64 newVerifiedAt,
        uint64 newExpiresAt,
        bytes32 externalRef
    ) external;

    function updateCountry(address user, bytes2 newCountry) external;

    function suspendIdentity(address user, bytes32 reason) external;
    function unsuspendIdentity(address user) external;
    function revokeIdentity(address user, bytes32 reason) external;

    function batchRegister(
        address[] calldata users,
        KycLevel[] calldata levels,
        bytes2[] calldata countries,
        uint64[] calldata verifiedAts,
        uint64[] calldata expiresAts,
        bytes32[] calldata externalRefs
    ) external;
}
