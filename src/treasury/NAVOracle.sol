// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {INAVOracle} from "./interfaces/INAVOracle.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @dev Minimal Chainlink aggregator interface (avoids adding a Chainlink dep).
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title Display-only NAV oracle.
/// @notice The Brivo vault settles 1:1 and does NOT use this oracle. The
///         price returned here drives UI display and the RescueManager's
///         emergency-redemption floor.
/// @dev    `priceOf` normalizes the Chainlink answer to 1e18. `valueInUsdc`
///         assumes the token has 18 decimals (true for brvUSTY).
contract NAVOracle is INAVOracle, AccessControl {
    mapping(address token => PriceFeed) private _feeds;
    mapping(address token => uint256) private _fallbackPrices;

    constructor(address admin) {
        if (admin == address(0)) revert TreasuryErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
    }

    function feedOf(address token) external view returns (PriceFeed memory) {
        return _feeds[token];
    }

    function priceOf(address token) public view returns (uint256 price, uint64 updatedAt) {
        PriceFeed memory feed = _feeds[token];
        if (feed.chainlinkFeed == address(0)) {
            uint256 fb = _fallbackPrices[token];
            if (fb == 0) revert TreasuryErrors.OracleNotConfigured(token);
            return (fb, uint64(block.timestamp));
        }

        IChainlinkAggregator agg = IChainlinkAggregator(feed.chainlinkFeed);
        (, int256 answer, , uint256 ts, ) = agg.latestRoundData();
        if (answer <= 0) revert TreasuryErrors.OracleInvalidAnswer(answer);
        if (ts + feed.maxAge < block.timestamp) {
            revert TreasuryErrors.OracleStale(ts, feed.maxAge);
        }

        uint8 feedDecimals = agg.decimals();
        uint256 raw = uint256(answer);
        if (feedDecimals < 18) {
            raw = raw * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            raw = raw / (10 ** (feedDecimals - 18));
        }
        if (feed.inverse) {
            raw = 1e36 / raw;
        }
        return (raw, uint64(ts));
    }

    function valueInUsdc(address token, uint256 amount) external view returns (uint256) {
        (uint256 price, ) = priceOf(token);
        return (amount * price) / 1e30;
    }

    function setFeed(address token, PriceFeed calldata feed)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (token == address(0)) revert TreasuryErrors.ZeroAddress();
        if (feed.maxAge == 0) revert TreasuryErrors.ZeroAmount();
        _feeds[token] = feed;
        emit FeedSet(token, feed.chainlinkFeed, feed.maxAge, feed.inverse);
    }

    function setFallbackPrice(address token, uint256 price)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (token == address(0)) revert TreasuryErrors.ZeroAddress();
        _fallbackPrices[token] = price;
        emit FallbackPriceSet(token, price);
    }
}
