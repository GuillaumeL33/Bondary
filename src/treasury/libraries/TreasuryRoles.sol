// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Role constants for the Brivo Treasury stack.
/// @notice All roles use OpenZeppelin AccessControl.
library TreasuryRoles {
    /// Operator that executes queued subscriptions / redemptions after
    /// the off-chain USDC <-> USDY swap. Typically a Gnosis Safe 2/3.
    bytes32 internal constant OPERATOR_ROLE = keccak256("BRIVO_TREASURY_OPERATOR_ROLE");

    /// KYC backend that registers / suspends / revokes identities.
    bytes32 internal constant KYC_OPERATOR_ROLE = keccak256("BRIVO_TREASURY_KYC_OPERATOR_ROLE");

    /// Product admin that registers products and tunes eligibility config.
    bytes32 internal constant PRODUCT_ADMIN_ROLE = keccak256("BRIVO_TREASURY_PRODUCT_ADMIN_ROLE");

    /// Treasury admin that pauses, configures fees, swaps NAV oracle.
    /// Typically a Gnosis Safe 3/5.
    bytes32 internal constant TREASURY_ADMIN_ROLE = keccak256("BRIVO_TREASURY_ADMIN_ROLE");

    /// Rescue council. Force-redeem, freeze, migrate. Multisig + 7d timelock.
    bytes32 internal constant RESCUE_ROLE = keccak256("BRIVO_TREASURY_RESCUE_ROLE");

    /// Pauser, scoped to per-contract `whenNotPaused` modifier.
    bytes32 internal constant PAUSER_ROLE = keccak256("BRIVO_TREASURY_PAUSER_ROLE");

    /// Vault role granted to subscription / redemption queue contracts so
    /// they can call `vault.depositFor` and `vault.redeemFor`.
    bytes32 internal constant VAULT_GATEWAY_ROLE = keccak256("BRIVO_TREASURY_VAULT_GATEWAY_ROLE");
}
