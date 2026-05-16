// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBrivoVault} from "./interfaces/IBrivoVault.sol";
import {IRedemptionQueue} from "./interfaces/IRedemptionQueue.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @title RedemptionQueue — user escrows brvUSTY, operator returns USDC, vault burns shares.
/// @dev    The queue must be allowlisted in `ProductEligibilityRegistry` so it
///         can hold shares (transfers to it are eligibility-checked otherwise).
///         Cancel is callable while paused so users can always exit.
contract RedemptionQueue is IRedemptionQueue, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant MIN_EXECUTION_WINDOW = 1 hours;
    uint64 public constant MAX_EXECUTION_WINDOW = 30 days;

    IBrivoVault public immutable vault;
    IERC20 public immutable usdc;

    uint64 public executionWindow;
    uint256 public nextOrderId;
    uint256 public totalPendingShares;

    mapping(uint256 orderId => Order) private _orders;

    constructor(
        IBrivoVault vault_,
        IERC20 usdc_,
        address admin,
        address operator,
        uint64 executionWindow_
    ) {
        if (
            address(vault_) == address(0) ||
            address(usdc_) == address(0) ||
            admin == address(0) ||
            operator == address(0)
        ) revert TreasuryErrors.ZeroAddress();
        if (executionWindow_ < MIN_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooShort(executionWindow_, MIN_EXECUTION_WINDOW);
        }
        if (executionWindow_ > MAX_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooLong(executionWindow_, MAX_EXECUTION_WINDOW);
        }

        vault = vault_;
        usdc = usdc_;
        executionWindow = executionWindow_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.OPERATOR_ROLE, operator);
        _grantRole(TreasuryRoles.PAUSER_ROLE, admin);

        emit VaultSet(address(vault_));
        emit UsdcTokenSet(address(usdc_));
        emit ExecutionWindowSet(0, executionWindow_);
    }

    // ---------------- views ----------------

    function orderOf(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    // ---------------- user ----------------

    function submit(uint128 sharesIn, uint128 minUsdcOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (sharesIn == 0) revert TreasuryErrors.ZeroAmount();
        if (minUsdcOut == 0) revert TreasuryErrors.ZeroAmount();

        orderId = ++nextOrderId;
        uint64 nowTs = uint64(block.timestamp);
        Order storage o = _orders[orderId];
        o.status = OrderStatus.Pending;
        o.user = msg.sender;
        o.sharesIn = sharesIn;
        o.minUsdcOut = minUsdcOut;
        o.submittedAt = nowTs;
        o.expiresAt = nowTs + executionWindow;

        totalPendingShares += sharesIn;
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), sharesIn);

        emit RedemptionSubmitted(orderId, msg.sender, sharesIn, minUsdcOut, o.expiresAt);
    }

    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (o.user != msg.sender) revert TreasuryErrors.OrderOwnerOnly(orderId);

        o.status = OrderStatus.Cancelled;
        uint256 amt = o.sharesIn;
        totalPendingShares -= amt;
        IERC20(address(vault)).safeTransfer(o.user, amt);
        emit RedemptionCancelled(orderId, o.user, amt);
    }

    function reclaimExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (block.timestamp < o.expiresAt) revert TreasuryErrors.OrderNotMature(orderId);

        o.status = OrderStatus.Expired;
        uint256 amt = o.sharesIn;
        totalPendingShares -= amt;
        IERC20(address(vault)).safeTransfer(o.user, amt);
        emit RedemptionExpired(orderId, o.user, amt);
    }

    // ---------------- operator ----------------

    function execute(uint256 orderId, uint128 usdcDelivered)
        external
        onlyRole(TreasuryRoles.OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        _execute(orderId, usdcDelivered);
    }

    function batchExecute(uint256[] calldata orderIds, uint128[] calldata usdcDelivered)
        external
        onlyRole(TreasuryRoles.OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (orderIds.length != usdcDelivered.length) revert TreasuryErrors.LengthMismatch();
        for (uint256 i; i < orderIds.length; ++i) {
            _execute(orderIds[i], usdcDelivered[i]);
        }
    }

    function _execute(uint256 orderId, uint128 usdcDelivered) internal {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (block.timestamp >= o.expiresAt) revert TreasuryErrors.OrderExpired(orderId);
        if (usdcDelivered < o.minUsdcOut) {
            revert TreasuryErrors.SlippageExceeded(usdcDelivered, o.minUsdcOut);
        }

        address user = o.user;
        uint256 shares = o.sharesIn;
        o.status = OrderStatus.Executed;
        totalPendingShares -= shares;

        usdc.safeTransferFrom(msg.sender, address(this), usdcDelivered);
        usdc.safeTransfer(user, usdcDelivered);
        vault.redeemFor(shares, msg.sender, address(this));

        emit RedemptionExecuted(orderId, user, usdcDelivered, shares, msg.sender);
    }

    function _ensurePending(Order storage o, uint256 orderId) internal view {
        if (o.status == OrderStatus.None) revert TreasuryErrors.OrderNotFound(orderId);
        if (o.status == OrderStatus.Executed) revert TreasuryErrors.OrderAlreadyExecuted(orderId);
        if (o.status == OrderStatus.Cancelled || o.status == OrderStatus.Expired) {
            revert TreasuryErrors.OrderAlreadyCancelled(orderId);
        }
    }

    // ---------------- admin ----------------

    function setExecutionWindow(uint64 newWindow)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (newWindow < MIN_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooShort(newWindow, MIN_EXECUTION_WINDOW);
        }
        if (newWindow > MAX_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooLong(newWindow, MAX_EXECUTION_WINDOW);
        }
        uint64 old = executionWindow;
        executionWindow = newWindow;
        emit ExecutionWindowSet(old, newWindow);
    }

    function pause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _unpause();
    }
}
