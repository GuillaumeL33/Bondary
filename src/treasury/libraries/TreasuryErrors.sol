// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Custom errors shared by the Brivo Treasury stack.
library TreasuryErrors {
    // ----- generic -----
    error ZeroAddress();
    error ZeroAmount();
    error LengthMismatch();
    error Reentrancy();
    error Paused();

    // ----- identity / eligibility -----
    error IdentityNotRegistered(address user);
    error IdentityNotVerified(address user);
    error IdentityExpired(address user);
    error IdentitySuspended(address user);
    error IdentityRevoked(address user);
    error InvalidKycLevel();
    error InvalidCountry();

    error ProductNotRegistered(bytes32 productId);
    error ProductAlreadyRegistered(bytes32 productId);
    error TokenAlreadyMapped(address token);
    error ProductFrozen(bytes32 productId);
    error ProductRedemptionOnly(bytes32 productId);
    error UserNotEligible(bytes32 productId, address user, bytes32 reason);

    // ----- vault -----
    error VaultUnderlyingMismatch();
    error VaultProductMismatch();
    error VaultInvariantBroken(uint256 totalSupply, uint256 totalAssets);
    error VaultCapExceeded(uint256 requested, uint256 cap);
    error VaultBelowMinimum(uint256 amount, uint256 minimum);
    error VaultRecipientNotEligible(address to);
    error VaultSenderNotEligible(address from);
    error VaultOwnerMismatch(address caller, address owner);

    // ----- queues -----
    error OrderNotFound(uint256 orderId);
    error OrderAlreadyExecuted(uint256 orderId);
    error OrderAlreadyCancelled(uint256 orderId);
    error OrderNotMature(uint256 orderId);
    error OrderExpired(uint256 orderId);
    error OrderOwnerOnly(uint256 orderId);
    error SlippageExceeded(uint256 received, uint256 minOut);
    error ExecutionWindowTooShort(uint64 window, uint64 minWindow);
    error ExecutionWindowTooLong(uint64 window, uint64 maxWindow);
    error CutoffPassed(uint64 cutoff, uint64 nowTs);

    // ----- fees / oracle / rescue -----
    error FeeTooHigh(uint16 fee, uint16 maxFee);
    error FeeRecipientRequired();

    error OracleStale(uint256 updatedAt, uint256 maxAge);
    error OracleInvalidAnswer(int256 answer);
    error OracleNotConfigured(address token);

    error RescueTimelockNotElapsed(uint64 readyAt, uint64 nowTs);
    error RescueProposalNotFound(bytes32 proposalId);
    error RescueProposalAlreadyExecuted(bytes32 proposalId);
    error RescueProposalCancelled(bytes32 proposalId);
    error RescueInvalidKind();
    error RescueUnsupportedKind(uint8 kind);
}
