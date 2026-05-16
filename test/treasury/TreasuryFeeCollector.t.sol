// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TreasuryFeeCollector} from "../../src/treasury/TreasuryFeeCollector.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

contract TreasuryFeeCollectorTest is Test {
    TreasuryFeeCollector internal fc;

    address internal admin = makeAddr("admin");
    address internal recipient = makeAddr("recipient");
    address internal alice = makeAddr("alice");

    bytes32 internal constant PRODUCT_ID = keccak256("brvUSTY");

    function setUp() public {
        fc = new TreasuryFeeCollector(admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        new TreasuryFeeCollector(address(0));
    }

    function test_defaultFees_areZero() public view {
        ITreasuryFeeCollector.ProductFees memory f = fc.feesOf(PRODUCT_ID);
        assertEq(f.subscriptionBps, 0);
        assertEq(f.redemptionBps, 0);
        assertEq(f.managementBps, 0);
        assertEq(f.performanceBps, 0);
        assertEq(f.recipient, address(0));
    }

    function test_setProductFees_acceptsValidConfig() public {
        ITreasuryFeeCollector.ProductFees memory f = ITreasuryFeeCollector.ProductFees({
            subscriptionBps: 25,
            redemptionBps: 25,
            managementBps: 50,
            performanceBps: 1000,
            recipient: recipient
        });
        vm.prank(admin);
        fc.setProductFees(PRODUCT_ID, f);
        ITreasuryFeeCollector.ProductFees memory stored = fc.feesOf(PRODUCT_ID);
        assertEq(stored.subscriptionBps, 25);
        assertEq(stored.recipient, recipient);
    }

    function test_setProductFees_revertsTooHigh() public {
        ITreasuryFeeCollector.ProductFees memory f = ITreasuryFeeCollector.ProductFees({
            subscriptionBps: 600, // > 500
            redemptionBps: 0,
            managementBps: 0,
            performanceBps: 0,
            recipient: recipient
        });
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.FeeTooHigh.selector, uint16(600), uint16(500))
        );
        fc.setProductFees(PRODUCT_ID, f);
    }

    function test_setProductFees_revertsRecipientRequired() public {
        ITreasuryFeeCollector.ProductFees memory f = ITreasuryFeeCollector.ProductFees({
            subscriptionBps: 25,
            redemptionBps: 0,
            managementBps: 0,
            performanceBps: 0,
            recipient: address(0)
        });
        vm.prank(admin);
        vm.expectRevert(TreasuryErrors.FeeRecipientRequired.selector);
        fc.setProductFees(PRODUCT_ID, f);
    }

    function test_setProductFees_onlyAdmin() public {
        ITreasuryFeeCollector.ProductFees memory f;
        vm.prank(alice);
        vm.expectRevert();
        fc.setProductFees(PRODUCT_ID, f);
    }

    function test_preview_returnsZero_whenNoFees() public view {
        assertEq(fc.previewSubscriptionFee(PRODUCT_ID, 1_000_000e18), 0);
        assertEq(fc.previewRedemptionFee(PRODUCT_ID, 1_000_000e18), 0);
    }

    function test_preview_returnsExpected_whenConfigured() public {
        ITreasuryFeeCollector.ProductFees memory f = ITreasuryFeeCollector.ProductFees({
            subscriptionBps: 25,  // 0.25%
            redemptionBps: 50,    // 0.50%
            managementBps: 0,
            performanceBps: 0,
            recipient: recipient
        });
        vm.prank(admin);
        fc.setProductFees(PRODUCT_ID, f);
        assertEq(fc.previewSubscriptionFee(PRODUCT_ID, 1_000_000e18), 2500e18);
        assertEq(fc.previewRedemptionFee(PRODUCT_ID, 1_000_000e18), 5000e18);
    }
}
