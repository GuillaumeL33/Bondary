// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBrivoVault} from "./interfaces/IBrivoVault.sol";
import {ISubscriptionQueue} from "./interfaces/ISubscriptionQueue.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @title SubscriptionQueue — user submits USDC, operator delivers USDY, vault mints brvUSTY.
/// @dev    Cancel is intentionally callable while paused so users can always exit.
///         Execute is paused-gated and operator-gated.
contract SubscriptionQueue is ISubscriptionQueue, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant MIN_EXECUTION_WINDOW = 1 hours;
    uint64 public constant MAX_EXECUTION_WINDOW = 30 days;

    IBrivoVault public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable usdy;

    address public operatorTreasury;
    uint64 public executionWindow;
    uint256 public nextOrderId;
    uint256 public totalPendingUsdc;

    mapping(uint256 orderId => Order) private _orders;

    constructor(
        IBrivoVault vault_,
        IERC20 usdc_,
        IERC20 usdy_,
        address operatorTreasury_,
        address admin,
        address operator,
        uint64 executionWindow_
    ) {
        if (
            address(vault_) == address(0) ||
            address(usdc_) == address(0) ||
            address(usdy_) == address(0) ||
            operatorTreasury_ == address(0) ||
            admin == address(0) ||
            operator == address(0)
        ) revert TreasuryErrors.ZeroAddress();
        if (executionWindow_ < MIN_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooShort(executionWindow_, MIN_EXECUTION_WINDOW);
        }
        if (executionWindow_ > MAX_EXECUTION_WINDOW) {
            revert TreasuryErrors.ExecutionWindowTooLong(executionWindow_, MAX_EXECUTION_WINDOW);
        }
        if (address(vault_.underlying()) != address(usdy_)) {
            revert TreasuryErrors.VaultUnderlyingMismatch();
        }

        vault = vault_;
        usdc = usdc_;
        usdy = usdy_;
        operatorTreasury = operatorTreasury_;
        executionWindow = executionWindow_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.OPERATOR_ROLE, operator);
        _grantRole(TreasuryRoles.PAUSER_ROLE, admin);

        emit VaultSet(address(vault_));
        emit UsdcTokenSet(address(usdc_));
        emit UsdyTokenSet(address(usdy_));
        emit OperatorTreasurySet(operatorTreasury_);
        emit ExecutionWindowSet(0, executionWindow_);
    }

    // ---------------- views ----------------

    function orderOf(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    // ---------------- user ----------------

    function submit(uint128 usdcIn, uint128 minSharesOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (usdcIn == 0) revert TreasuryErrors.ZeroAmount();
        if (minSharesOut == 0) revert TreasuryErrors.ZeroAmount();

        orderId = ++nextOrderId;
        uint64 nowTs = uint64(block.timestamp);
        Order storage o = _orders[orderId];
        o.status = OrderStatus.Pending;
        o.user = msg.sender;
        o.usdcIn = usdcIn;
        o.minSharesOut = minSharesOut;
        o.submittedAt = nowTs;
        o.expiresAt = nowTs + executionWindow;

        totalPendingUsdc += usdcIn;
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        emit SubscriptionSubmitted(orderId, msg.sender, usdcIn, minSharesOut, o.expiresAt);
    }

    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (o.user != msg.sender) revert TreasuryErrors.OrderOwnerOnly(orderId);

        o.status = OrderStatus.Cancelled;
        uint256 refund = o.usdcIn;
        totalPendingUsdc -= refund;
        usdc.safeTransfer(o.user, refund);
        emit SubscriptionCancelled(orderId, o.user, refund);
    }

    function reclaimExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (block.timestamp < o.expiresAt) revert TreasuryErrors.OrderNotMature(orderId);

        o.status = OrderStatus.Expired;
        uint256 refund = o.usdcIn;
        totalPendingUsdc -= refund;
        usdc.safeTransfer(o.user, refund);
        emit SubscriptionExpired(orderId, o.user, refund);
    }

    // ---------------- operator ----------------

    function execute(uint256 orderId, uint128 usdyDelivered)
        external
        onlyRole(TreasuryRoles.OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        _execute(orderId, usdyDelivered);
    }

    function batchExecute(uint256[] calldata orderIds, uint128[] calldata usdyDelivered)
        external
        onlyRole(TreasuryRoles.OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (orderIds.length != usdyDelivered.length) revert TreasuryErrors.LengthMismatch();
        for (uint256 i; i < orderIds.length; ++i) {
            _execute(orderIds[i], usdyDelivered[i]);
        }
    }

    function _execute(uint256 orderId, uint128 usdyDelivered) internal {
        Order storage o = _orders[orderId];
        _ensurePending(o, orderId);
        if (block.timestamp >= o.expiresAt) revert TreasuryErrors.OrderExpired(orderId);
        if (usdyDelivered < o.minSharesOut) {
            revert TreasuryErrors.SlippageExceeded(usdyDelivered, o.minSharesOut);
        }

        address user = o.user;
        uint256 usdcOut = o.usdcIn;
        o.status = OrderStatus.Executed;
        totalPendingUsdc -= usdcOut;

        usdy.safeTransferFrom(msg.sender, address(this), usdyDelivered);
        usdy.forceApprove(address(vault), usdyDelivered);
        vault.depositFor(usdyDelivered, user, address(this));

        usdc.safeTransfer(operatorTreasury, usdcOut);

        emit SubscriptionExecuted(orderId, user, usdyDelivered, usdyDelivered, msg.sender);
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

    function setOperatorTreasury(address newTreasury)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (newTreasury == address(0)) revert TreasuryErrors.ZeroAddress();
        operatorTreasury = newTreasury;
        emit OperatorTreasurySet(newTreasury);
    }

    function pause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _unpause();
    }
}
