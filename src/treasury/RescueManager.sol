// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IBrivoVault} from "./interfaces/IBrivoVault.sol";
import {IProductEligibilityRegistry} from "./interfaces/IProductEligibilityRegistry.sol";
import {IRescueManager} from "./interfaces/IRescueManager.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @title Emergency operations with a 7-day timelock.
/// @notice Implements V1 proposal kinds:
///         - PauseVault / UnpauseVault
///         - FreezeProduct
///         - SetEmergencyHaircutBps
///         - ReclaimExcess
///         ForceRedeem and MigrateUnderlying are declared in the interface
///         but not implemented in V1 — they require more design work and
///         will land in V1.1.
/// @dev    Must hold:
///         - `PAUSER_ROLE` and `RESCUE_ROLE` on `BrivoVault`
///         - `PRODUCT_ADMIN_ROLE` on `ProductEligibilityRegistry`
///         Granted by the deploy script.
contract RescueManager is IRescueManager, AccessControl {
    uint64 public constant TIMELOCK_DELAY = 7 days;
    uint16 public constant MAX_HAIRCUT_BPS = 500;

    IBrivoVault public immutable vault;
    IProductEligibilityRegistry public immutable eligibility;

    uint16 public emergencyHaircutBps;
    uint256 public proposalNonce;

    mapping(bytes32 proposalId => Proposal) private _proposals;

    constructor(
        IBrivoVault vault_,
        IProductEligibilityRegistry eligibility_,
        address admin,
        address rescuer
    ) {
        if (
            address(vault_) == address(0) ||
            address(eligibility_) == address(0) ||
            admin == address(0) ||
            rescuer == address(0)
        ) revert TreasuryErrors.ZeroAddress();
        vault = vault_;
        eligibility = eligibility_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.RESCUE_ROLE, rescuer);
    }

    function timelockDelay() external pure returns (uint64) {
        return TIMELOCK_DELAY;
    }

    function proposalOf(bytes32 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function propose(ProposalKind kind, bytes calldata data)
        external
        onlyRole(TreasuryRoles.RESCUE_ROLE)
        returns (bytes32 proposalId)
    {
        if (kind == ProposalKind.None) revert TreasuryErrors.RescueInvalidKind();
        uint256 nonce = ++proposalNonce;
        proposalId = keccak256(abi.encode(kind, data, nonce, block.timestamp, address(this)));

        uint64 nowTs = uint64(block.timestamp);
        uint64 readyAt = nowTs + TIMELOCK_DELAY;
        _proposals[proposalId] = Proposal({
            kind: kind,
            proposedAt: nowTs,
            readyAt: readyAt,
            executed: false,
            cancelled: false,
            data: data
        });
        emit ProposalCreated(proposalId, kind, readyAt, data);
    }

    function execute(bytes32 proposalId)
        external
        onlyRole(TreasuryRoles.RESCUE_ROLE)
    {
        Proposal storage p = _proposals[proposalId];
        if (p.kind == ProposalKind.None) revert TreasuryErrors.RescueProposalNotFound(proposalId);
        if (p.executed) revert TreasuryErrors.RescueProposalAlreadyExecuted(proposalId);
        if (p.cancelled) revert TreasuryErrors.RescueProposalCancelled(proposalId);
        if (block.timestamp < p.readyAt) {
            revert TreasuryErrors.RescueTimelockNotElapsed(p.readyAt, uint64(block.timestamp));
        }
        p.executed = true;
        _dispatch(p.kind, p.data);
        emit ProposalExecuted(proposalId, p.kind);
    }

    function cancel(bytes32 proposalId)
        external
        onlyRole(TreasuryRoles.RESCUE_ROLE)
    {
        Proposal storage p = _proposals[proposalId];
        if (p.kind == ProposalKind.None) revert TreasuryErrors.RescueProposalNotFound(proposalId);
        if (p.executed) revert TreasuryErrors.RescueProposalAlreadyExecuted(proposalId);
        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    function _dispatch(ProposalKind kind, bytes memory data) internal {
        if (kind == ProposalKind.PauseVault) {
            vault.pause();
        } else if (kind == ProposalKind.UnpauseVault) {
            vault.unpause();
        } else if (kind == ProposalKind.FreezeProduct) {
            bytes32 productId = abi.decode(data, (bytes32));
            eligibility.setProductStatus(
                productId,
                IProductEligibilityRegistry.ProductStatus.Frozen
            );
        } else if (kind == ProposalKind.SetEmergencyHaircutBps) {
            uint16 newBps = abi.decode(data, (uint16));
            if (newBps > MAX_HAIRCUT_BPS) revert TreasuryErrors.FeeTooHigh(newBps, MAX_HAIRCUT_BPS);
            uint16 old = emergencyHaircutBps;
            emergencyHaircutBps = newBps;
            emit EmergencyHaircutBpsSet(old, newBps);
        } else if (kind == ProposalKind.ReclaimExcess) {
            address recipient = abi.decode(data, (address));
            vault.reclaimExcess(recipient);
        } else {
            // ForceRedeem, MigrateUnderlying: tracked for V1.1.
            revert TreasuryErrors.RescueUnsupportedKind(uint8(kind));
        }
    }
}
