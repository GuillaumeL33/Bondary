// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITreasuryFeeCollector} from "./interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @title Treasury fee collector — V1 zero-fee, V2-ready storage.
/// @notice In V1, all product fees are zero. The contract is still deployed so
///         V1.1+ can flip fees on without changing vault or queue addresses.
///         `maxFeeBps` caps subscription / redemption / management fees at
///         5%, performance at 50% (a posteriori cap).
contract TreasuryFeeCollector is ITreasuryFeeCollector, AccessControl {
    using SafeERC20 for IERC20;

    uint16 public constant maxFeeBps = 500;
    uint16 public constant MAX_PERF_FEE_BPS = 5_000;

    mapping(bytes32 productId => ProductFees) private _fees;

    constructor(address admin) {
        if (admin == address(0)) revert TreasuryErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
    }

    function feesOf(bytes32 productId) external view returns (ProductFees memory) {
        return _fees[productId];
    }

    function previewSubscriptionFee(bytes32 productId, uint256 amount)
        external
        view
        returns (uint256)
    {
        return (amount * _fees[productId].subscriptionBps) / 10_000;
    }

    function previewRedemptionFee(bytes32 productId, uint256 amount)
        external
        view
        returns (uint256)
    {
        return (amount * _fees[productId].redemptionBps) / 10_000;
    }

    function setProductFees(bytes32 productId, ProductFees calldata fees)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (fees.subscriptionBps > maxFeeBps) revert TreasuryErrors.FeeTooHigh(fees.subscriptionBps, maxFeeBps);
        if (fees.redemptionBps > maxFeeBps)   revert TreasuryErrors.FeeTooHigh(fees.redemptionBps, maxFeeBps);
        if (fees.managementBps > maxFeeBps)   revert TreasuryErrors.FeeTooHigh(fees.managementBps, maxFeeBps);
        if (fees.performanceBps > MAX_PERF_FEE_BPS) {
            revert TreasuryErrors.FeeTooHigh(fees.performanceBps, MAX_PERF_FEE_BPS);
        }

        uint16 totalNonPerf = fees.subscriptionBps + fees.redemptionBps + fees.managementBps;
        if ((totalNonPerf + fees.performanceBps) > 0 && fees.recipient == address(0)) {
            revert TreasuryErrors.FeeRecipientRequired();
        }

        _fees[productId] = fees;
        emit ProductFeesSet(
            productId,
            fees.subscriptionBps,
            fees.redemptionBps,
            fees.managementBps,
            fees.performanceBps,
            fees.recipient
        );
    }

    function collect(
        bytes32 productId,
        address token,
        address from,
        uint256 amount,
        uint8 feeType
    ) external onlyRole(TreasuryRoles.FEE_GATEWAY_ROLE) {
        if (amount == 0) return;
        ProductFees memory f = _fees[productId];
        if (f.recipient == address(0)) revert TreasuryErrors.FeeRecipientRequired();
        IERC20(token).safeTransferFrom(from, f.recipient, amount);
        emit FeesCollected(productId, token, amount, feeType);
    }
}
