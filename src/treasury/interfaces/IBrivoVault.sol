// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProductEligibilityRegistry} from "./IProductEligibilityRegistry.sol";
import {ITreasuryFeeCollector} from "./ITreasuryFeeCollector.sol";

/// @title Brivo Treasury vault — strict 1:1 wrap of a non-rebasing underlying.
/// @notice Implements the ERC-4626 surface with a hard-coded `convertToShares
///         (assets) == assets` and `convertToAssets(shares) == shares`. The
///         product is non-rebasing: yield accrues through the *price* of the
///         underlying in USDC, not through a changing share/asset ratio.
/// @dev    Mints and burns are restricted to addresses holding
///         `VAULT_GATEWAY_ROLE` — typically the `SubscriptionQueue` and
///         `RedemptionQueue`. Direct user-initiated `deposit` / `redeem` is
///         disabled to enforce the queue-based flow.
interface IBrivoVault {
    // ---------------- events ----------------

    event Subscribed(address indexed by, address indexed receiver, uint256 assets, uint256 shares);
    event Redeemed(address indexed by, address indexed receiver, uint256 assets, uint256 shares);
    event ProductIdSet(bytes32 indexed productId);
    event EligibilityRegistrySet(address indexed registry);
    event FeeCollectorSet(address indexed collector);
    event SubscriptionCapSet(uint256 oldCap, uint256 newCap);
    event MinSubscriptionSet(uint256 oldMin, uint256 newMin);
    event ExcessReclaimed(address indexed to, uint256 amount);

    // ---------------- views ----------------

    function underlying() external view returns (IERC20);
    function productId() external view returns (bytes32);
    function eligibility() external view returns (IProductEligibilityRegistry);
    function feeCollector() external view returns (ITreasuryFeeCollector);

    /// @notice Total underlying held by the vault. Always >= totalSupply (I1).
    function totalAssets() external view returns (uint256);

    /// @notice 1:1 strict — returns `assets` unchanged.
    function convertToShares(uint256 assets) external pure returns (uint256);
    /// @notice 1:1 strict — returns `shares` unchanged.
    function convertToAssets(uint256 shares) external pure returns (uint256);

    /// @notice Hard cap on the total supply of brvUSTY (V1 safety lever).
    function subscriptionCap() external view returns (uint256);
    /// @notice Minimum subscription per call.
    function minSubscription() external view returns (uint256);

    // ---------------- mutating — gateway only ----------------

    /// @notice Pull `assets` of underlying from `caller`, mint `assets` shares
    ///         to `receiver`. Caller must hold `VAULT_GATEWAY_ROLE` (i.e.
    ///         must be the SubscriptionQueue).
    /// @return shares Always equal to `assets` (1:1 strict).
    function depositFor(uint256 assets, address receiver, address caller) external returns (uint256 shares);

    /// @notice Burn `shares` from `owner`, transfer `shares` of underlying
    ///         to `receiver`. Caller must hold `VAULT_GATEWAY_ROLE` (i.e.
    ///         must be the RedemptionQueue).
    /// @return assets Always equal to `shares` (1:1 strict).
    function redeemFor(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ---------------- mutating — admin ----------------

    function setSubscriptionCap(uint256 newCap) external;
    function setMinSubscription(uint256 newMin) external;
    function setFeeCollector(address newCollector) external;
    function pause() external;
    function unpause() external;

    /// @notice If the vault holds more underlying than its share supply (operator
    ///         over-delivered), the rescue manager can reclaim the excess.
    function reclaimExcess(address to) external returns (uint256 amount);
}
