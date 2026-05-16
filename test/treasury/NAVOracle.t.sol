// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NAVOracle} from "../../src/treasury/NAVOracle.sol";
import {INAVOracle} from "../../src/treasury/interfaces/INAVOracle.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {MockChainlink} from "./mocks/MockChainlink.sol";

contract NAVOracleTest is Test {
    NAVOracle internal oracle;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal token = makeAddr("token");

    function setUp() public {
        oracle = new NAVOracle(admin);
    }

    function test_priceOf_revertsNoConfig() public {
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.OracleNotConfigured.selector, token)
        );
        oracle.priceOf(token);
    }

    function test_priceOf_fallback() public {
        vm.prank(admin);
        oracle.setFallbackPrice(token, 1.05e18);
        (uint256 price, uint64 ts) = oracle.priceOf(token);
        assertEq(price, 1.05e18);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_priceOf_chainlink_8decimals() public {
        // $1.05 with 8 decimals (typical Chainlink USD feed)
        MockChainlink agg = new MockChainlink(int256(105_000_000), 8, block.timestamp);
        vm.prank(admin);
        oracle.setFeed(
            token,
            INAVOracle.PriceFeed({chainlinkFeed: address(agg), maxAge: 1 days, inverse: false})
        );
        (uint256 price, ) = oracle.priceOf(token);
        assertEq(price, 1.05e18);
    }

    function test_priceOf_chainlink_revertsStale() public {
        MockChainlink agg = new MockChainlink(int256(1e8), 8, block.timestamp);
        vm.prank(admin);
        oracle.setFeed(
            token,
            INAVOracle.PriceFeed({chainlinkFeed: address(agg), maxAge: 1 hours, inverse: false})
        );
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        oracle.priceOf(token);
    }

    function test_priceOf_chainlink_revertsInvalidAnswer() public {
        MockChainlink agg = new MockChainlink(int256(-1), 8, block.timestamp);
        vm.prank(admin);
        oracle.setFeed(
            token,
            INAVOracle.PriceFeed({chainlinkFeed: address(agg), maxAge: 1 days, inverse: false})
        );
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.OracleInvalidAnswer.selector, int256(-1))
        );
        oracle.priceOf(token);
    }

    function test_valueInUsdc_18decToken_at1_05() public {
        vm.prank(admin);
        oracle.setFallbackPrice(token, 1.05e18);
        // 1000 tokens (1e18 base) at $1.05 = $1050 = 1050e6 USDC
        assertEq(oracle.valueInUsdc(token, 1000e18), 1050e6);
    }

    function test_setFeed_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.setFeed(
            token,
            INAVOracle.PriceFeed({chainlinkFeed: address(1), maxAge: 1 days, inverse: false})
        );
    }

    function test_setFeed_revertsZeroMaxAge() public {
        vm.prank(admin);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        oracle.setFeed(
            token,
            INAVOracle.PriceFeed({chainlinkFeed: address(1), maxAge: 0, inverse: false})
        );
    }

    function test_setFallbackPrice_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.setFallbackPrice(token, 1e18);
    }
}
