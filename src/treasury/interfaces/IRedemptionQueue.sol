// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBrivoVault} from "./IBrivoVault.sol";

/// @title Redemption queue — user submits brvUSTY, operator returns USDC, vault burns brvUSTY.
///
/// Lifecycle:
///
///   submit() ── pending (brvUSTY escrowed in queue) ──> execute() ── executed (USDC paid out)
///                            │
///                            └──> cancel() ── cancelled (brvUSTY returned)
///                            │
///                            └──> expire() ── expired (brvUSTY claimable by user)
interface IRedemptionQueue {
    enum OrderStatus {
        None,       // 0
        Pending,    // 1 — brvUSTY escrowed, awaiting operator
        Executed,   // 2 — USDC paid to user, brvUSTY burned
        Cancelled,  // 3 — brvUSTY returned to user
        Expired     // 4 — past expiry, brvUSTY claimable by user
    }

    struct Order {
        OrderStatus status;
        address user;          // who escrowed brvUSTY and receives USDC
        uint128 sharesIn;      // brvUSTY escrowed at submit
        uint128 minUsdcOut;    // slippage floor in USDC
        uint64 submittedAt;
        uint64 expiresAt;
    }

    // ---------------- events ----------------

    event RedemptionSubmitted(
        uint256 indexed orderId,
        address indexed user,
        uint256 sharesIn,
        uint256 minUsdcOut,
        uint64 expiresAt
    );
    event RedemptionExecuted(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdcDelivered,
        uint256 sharesBurned,
        address indexed operator
    );
    event RedemptionCancelled(uint256 indexed orderId, address indexed user, uint256 sharesReturned);
    event RedemptionExpired(uint256 indexed orderId, address indexed user, uint256 sharesReturned);

    event ExecutionWindowSet(uint64 oldWindow, uint64 newWindow);
    event UsdcTokenSet(address indexed usdc);
    event VaultSet(address indexed vault);

    // ---------------- views ----------------

    function vault() external view returns (IBrivoVault);
    function usdc() external view returns (IERC20);
    function executionWindow() external view returns (uint64);
    function nextOrderId() external view returns (uint256);
    function orderOf(uint256 orderId) external view returns (Order memory);
    function totalPendingShares() external view returns (uint256);

    // ---------------- mutating — user ----------------

    function submit(uint128 sharesIn, uint128 minUsdcOut) external returns (uint256 orderId);
    function cancel(uint256 orderId) external;
    function reclaimExpired(uint256 orderId) external;

    // ---------------- mutating — operator ----------------

    function execute(uint256 orderId, uint128 usdcDelivered) external;
    function batchExecute(uint256[] calldata orderIds, uint128[] calldata usdcDelivered) external;

    // ---------------- mutating — admin ----------------

    function setExecutionWindow(uint64 newWindow) external;
    function pause() external;
    function unpause() external;
}
