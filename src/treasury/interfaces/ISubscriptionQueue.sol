// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBrivoVault} from "./IBrivoVault.sol";

/// @title Subscription queue — user submits USDC, operator delivers USDY, vault mints brvUSTY.
///
/// Lifecycle of an order:
///
///   submit() ── pending ──> execute() ── executed (USDY in vault, brvUSTY minted)
///                  │
///                  └──> cancel() ── cancelled (USDC refunded)
///                  │
///                  └──> expire() ── expired (USDC refundable by user)
///
/// The user always specifies `minSharesOut`: if the operator-reported amount
/// of USDY received off-chain is below this floor, `execute()` reverts and
/// the order remains pending.
interface ISubscriptionQueue {
    enum OrderStatus {
        None,       // 0
        Pending,    // 1 — awaiting operator execution
        Executed,   // 2 — brvUSTY minted to user
        Cancelled,  // 3 — USDC refunded
        Expired     // 4 — past expiry, refundable by user
    }

    struct Order {
        OrderStatus status;
        address user;          // who paid USDC and receives brvUSTY
        uint128 usdcIn;        // USDC pulled from the user at submit
        uint128 minSharesOut;  // slippage floor in brvUSTY
        uint64 submittedAt;
        uint64 expiresAt;
    }

    // ---------------- events ----------------

    event SubscriptionSubmitted(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdcIn,
        uint256 minSharesOut,
        uint64 expiresAt
    );
    event SubscriptionExecuted(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdyDelivered,
        uint256 sharesMinted,
        address indexed operator
    );
    event SubscriptionCancelled(uint256 indexed orderId, address indexed user, uint256 usdcRefunded);
    event SubscriptionExpired(uint256 indexed orderId, address indexed user, uint256 usdcRefunded);

    event ExecutionWindowSet(uint64 oldWindow, uint64 newWindow);
    event UsdcTokenSet(address indexed usdc);
    event UsdyTokenSet(address indexed usdy);
    event VaultSet(address indexed vault);
    event OperatorTreasurySet(address indexed treasury);

    // ---------------- views ----------------

    function vault() external view returns (IBrivoVault);
    function usdc() external view returns (IERC20);
    function usdy() external view returns (IERC20);
    function operatorTreasury() external view returns (address);

    function executionWindow() external view returns (uint64);
    function nextOrderId() external view returns (uint256);
    function orderOf(uint256 orderId) external view returns (Order memory);
    function totalPendingUsdc() external view returns (uint256);

    // ---------------- mutating — user ----------------

    /// @notice Submit a new subscription order. Pulls `usdcIn` USDC from msg.sender.
    ///         The order can be executed by an operator within `executionWindow`,
    ///         and only if the operator delivers at least `minSharesOut` USDY
    ///         to the vault.
    function submit(uint128 usdcIn, uint128 minSharesOut) external returns (uint256 orderId);

    /// @notice Cancel a pending order. USDC is refunded to the user. Only the
    ///         order owner can cancel.
    function cancel(uint256 orderId) external;

    /// @notice Reclaim USDC of an expired order (after `expiresAt`). Anyone
    ///         can trigger but funds go back to the order owner.
    function reclaimExpired(uint256 orderId) external;

    // ---------------- mutating — operator ----------------

    /// @notice Execute a pending order after delivering `usdyDelivered` USDY
    ///         to the vault. The USDC corresponding to the order is
    ///         transferred from this contract to `operatorTreasury` so the
    ///         operator can settle the off-chain swap.
    ///
    ///         Reverts if `usdyDelivered < order.minSharesOut`. The USDY is
    ///         pulled from `msg.sender` (must approve this contract first).
    function execute(uint256 orderId, uint128 usdyDelivered) external;

    /// @notice Batch execute multiple orders in FIFO order.
    function batchExecute(uint256[] calldata orderIds, uint128[] calldata usdyDelivered) external;

    // ---------------- mutating — admin ----------------

    function setExecutionWindow(uint64 newWindow) external;
    function setOperatorTreasury(address newTreasury) external;
    function pause() external;
    function unpause() external;
}
