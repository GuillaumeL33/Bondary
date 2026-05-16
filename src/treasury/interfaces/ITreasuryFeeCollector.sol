// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Fee accounting for the Brivo Treasury stack.
/// @notice V1 always reports zero fees (frais V1 = 0). This contract is
///         deployed nonetheless so V1.1/V2 can flip on fees without changing
///         the vault or queue addresses (back-compat).
interface ITreasuryFeeCollector {
    struct ProductFees {
        uint16 subscriptionBps;  // applied at SubscriptionQueue.execute()
        uint16 redemptionBps;    // applied at RedemptionQueue.execute()
        uint16 managementBps;    // annualized, applied on accrual basis (V2+)
        uint16 performanceBps;   // on NAV growth (V2+)
        address recipient;
    }

    event ProductFeesSet(
        bytes32 indexed productId,
        uint16 subscriptionBps,
        uint16 redemptionBps,
        uint16 managementBps,
        uint16 performanceBps,
        address recipient
    );
    event FeesCollected(
        bytes32 indexed productId,
        address indexed token,
        uint256 amount,
        uint8 feeType // 0=sub, 1=redeem, 2=mgmt, 3=perf
    );

    function feesOf(bytes32 productId) external view returns (ProductFees memory);
    function maxFeeBps() external view returns (uint16);

    /// @notice Returns the fee in token units to deduct from `amount` for
    ///         the given product and fee type. Zero in V1.
    function previewSubscriptionFee(bytes32 productId, uint256 amount) external view returns (uint256);
    function previewRedemptionFee(bytes32 productId, uint256 amount) external view returns (uint256);

    function setProductFees(bytes32 productId, ProductFees calldata fees) external;

    /// @notice Called by the vault / queues. Pulls `amount` from `from` and
    ///         records it as fee for `productId`/`feeType`.
    function collect(
        bytes32 productId,
        address token,
        address from,
        uint256 amount,
        uint8 feeType
    ) external;
}
