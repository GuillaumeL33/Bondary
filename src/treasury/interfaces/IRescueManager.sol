// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Emergency operations for Brivo Treasury products.
/// @notice All rescue actions are protected by a 7-day timelock between
///         proposal and execution. Proposals can be cancelled by the rescue
///         council at any time before execution.
interface IRescueManager {
    enum ProposalKind {
        None,                  // 0
        PauseVault,            // 1
        UnpauseVault,          // 2
        FreezeProduct,         // 3 — sets ProductEligibilityRegistry status to Frozen
        ForceRedeem,           // 4 — admin-driven redemption at oracle floor
        SetEmergencyHaircutBps,// 5 — adjust haircut for ForceRedeem
        MigrateUnderlying,     // 6 — move underlying to a successor vault
        ReclaimExcess          // 7 — reclaim over-delivered underlying
    }

    struct Proposal {
        ProposalKind kind;
        uint64 proposedAt;
        uint64 readyAt;
        bool executed;
        bool cancelled;
        bytes data; // ABI-encoded params; layout depends on `kind`
    }

    event ProposalCreated(
        bytes32 indexed proposalId,
        ProposalKind indexed kind,
        uint64 readyAt,
        bytes data
    );
    event ProposalExecuted(bytes32 indexed proposalId, ProposalKind indexed kind);
    event ProposalCancelled(bytes32 indexed proposalId);
    event EmergencyHaircutBpsSet(uint16 oldBps, uint16 newBps);

    function timelockDelay() external view returns (uint64);
    function emergencyHaircutBps() external view returns (uint16);
    function proposalOf(bytes32 proposalId) external view returns (Proposal memory);

    function propose(ProposalKind kind, bytes calldata data) external returns (bytes32 proposalId);
    function execute(bytes32 proposalId) external;
    function cancel(bytes32 proposalId) external;
}
