// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Role constants for the Brivo Treasury stack.
library TreasuryRoles {
    bytes32 internal constant OPERATOR_ROLE = keccak256("BRIVO_TREASURY_OPERATOR_ROLE");
    bytes32 internal constant KYC_OPERATOR_ROLE = keccak256("BRIVO_TREASURY_KYC_OPERATOR_ROLE");
    bytes32 internal constant PRODUCT_ADMIN_ROLE = keccak256("BRIVO_TREASURY_PRODUCT_ADMIN_ROLE");
    bytes32 internal constant TREASURY_ADMIN_ROLE = keccak256("BRIVO_TREASURY_ADMIN_ROLE");
    bytes32 internal constant RESCUE_ROLE = keccak256("BRIVO_TREASURY_RESCUE_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("BRIVO_TREASURY_PAUSER_ROLE");
    bytes32 internal constant VAULT_GATEWAY_ROLE = keccak256("BRIVO_TREASURY_VAULT_GATEWAY_ROLE");
    bytes32 internal constant FEE_GATEWAY_ROLE = keccak256("BRIVO_TREASURY_FEE_GATEWAY_ROLE");
}
