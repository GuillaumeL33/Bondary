// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Display-only NAV oracle for Brivo Treasury products.
/// @notice The Brivo vault is **non-rebasing 1:1**: it does NOT use the NAV
///         oracle to settle subscriptions or redemptions. The oracle is
///         used only for UI display (price in USDC) and for the rescue
///         manager's emergency redemption floor (I6).
interface INAVOracle {
    struct PriceFeed {
        address chainlinkFeed;   // Chainlink aggregator USDY/USD
        uint64 maxAge;           // staleness threshold (seconds)
        bool inverse;            // if the feed is USD/USDY instead of USDY/USD
    }

    event FeedSet(address indexed token, address chainlinkFeed, uint64 maxAge, bool inverse);
    event FallbackPriceSet(address indexed token, uint256 price);

    function feedOf(address token) external view returns (PriceFeed memory);

    /// @notice Latest price of 1 unit of `token` denominated in USDC, scaled to 1e18.
    function priceOf(address token) external view returns (uint256 price, uint64 updatedAt);

    /// @notice Price of `amount` of `token` in USDC (USDC has 6 decimals).
    function valueInUsdc(address token, uint256 amount) external view returns (uint256 usdc);

    function setFeed(address token, PriceFeed calldata feed) external;
    function setFallbackPrice(address token, uint256 price) external;
}
