// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrivoVault} from "../../src/treasury/BrivoVault.sol";
import {SubscriptionQueue} from "../../src/treasury/SubscriptionQueue.sol";
import {GlobalIdentityRegistry} from "../../src/treasury/compliance/GlobalIdentityRegistry.sol";
import {ProductEligibilityRegistry} from "../../src/treasury/compliance/ProductEligibilityRegistry.sol";
import {IGlobalIdentityRegistry} from "../../src/treasury/interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../../src/treasury/interfaces/IProductEligibilityRegistry.sol";
import {ISubscriptionQueue} from "../../src/treasury/interfaces/ISubscriptionQueue.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

import {MockToken} from "./mocks/MockToken.sol";

contract SubscriptionQueueTest is Test {
    BrivoVault internal vault;
    SubscriptionQueue internal queue;
    GlobalIdentityRegistry internal gir;
    ProductEligibilityRegistry internal per;
    MockToken internal usdc;
    MockToken internal usdy;

    address internal admin = makeAddr("admin");
    address internal kycOperator = makeAddr("kycOperator");
    address internal productAdmin = makeAddr("productAdmin");
    address internal operator = makeAddr("operator");
    address internal operatorTreasury = makeAddr("operatorTreasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant PRODUCT_ID = keccak256("brvUSTY");
    uint64 internal constant WINDOW = 1 days;

    function setUp() public {
        gir = new GlobalIdentityRegistry(admin, kycOperator);
        per = new ProductEligibilityRegistry(admin, gir, productAdmin);
        usdc = new MockToken("Mock USDC", "USDC", 6);
        usdy = new MockToken("Mock USDY", "USDY", 18);

        vault = new BrivoVault(
            "Brivo US Treasury Yield",
            "brvUSTY",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin,
            10_000_000e18,
            100e18
        );

        queue = new SubscriptionQueue(
            vault,
            IERC20(address(usdc)),
            IERC20(address(usdy)),
            operatorTreasury,
            admin,
            operator,
            WINDOW
        );

        vm.prank(admin);
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, address(queue));

        vm.prank(productAdmin);
        per.registerProduct(PRODUCT_ID, address(vault), IGlobalIdentityRegistry.KycLevel.Basic, false);

        vm.startPrank(kycOperator);
        gir.registerIdentity(
            alice, IGlobalIdentityRegistry.KycLevel.Basic, bytes2("FR"),
            uint64(block.timestamp), uint64(block.timestamp + 365 days), bytes32("alice")
        );
        gir.registerIdentity(
            bob, IGlobalIdentityRegistry.KycLevel.Basic, bytes2("DE"),
            uint64(block.timestamp), uint64(block.timestamp + 365 days), bytes32("bob")
        );
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdy.mint(operator, 10_000_000e18);

        vm.prank(alice);
        usdc.approve(address(queue), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(queue), type(uint256).max);
        vm.prank(operator);
        usdy.approve(address(queue), type(uint256).max);
    }

    // ---------------- constructor ----------------

    function test_constructor_revertsUnderlyingMismatch() public {
        MockToken otherUsdy = new MockToken("Other", "OUSDY", 18);
        vm.expectRevert(TreasuryErrors.VaultUnderlyingMismatch.selector);
        new SubscriptionQueue(
            vault, IERC20(address(usdc)), IERC20(address(otherUsdy)),
            operatorTreasury, admin, operator, WINDOW
        );
    }

    function test_constructor_revertsWindowTooShort() public {
        vm.expectRevert();
        new SubscriptionQueue(
            vault, IERC20(address(usdc)), IERC20(address(usdy)),
            operatorTreasury, admin, operator, 30 minutes
        );
    }

    function test_constructor_revertsWindowTooLong() public {
        vm.expectRevert();
        new SubscriptionQueue(
            vault, IERC20(address(usdc)), IERC20(address(usdy)),
            operatorTreasury, admin, operator, 31 days
        );
    }

    // ---------------- submit ----------------

    function test_submit_pullsUsdcAndCreatesOrder() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);

        assertEq(id, 1);
        ISubscriptionQueue.Order memory o = queue.orderOf(id);
        assertEq(uint8(o.status), uint8(ISubscriptionQueue.OrderStatus.Pending));
        assertEq(o.user, alice);
        assertEq(o.usdcIn, 1000e6);
        assertEq(o.minSharesOut, 990e18);
        assertEq(o.expiresAt, block.timestamp + WINDOW);

        assertEq(usdc.balanceOf(address(queue)), 1000e6);
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 1000e6);
        assertEq(queue.totalPendingUsdc(), 1000e6);
    }

    function test_submit_revertsZeroUsdc() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        queue.submit(0, 990e18);
    }

    function test_submit_revertsZeroMinShares() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        queue.submit(1000e6, 0);
    }

    function test_submit_revertsWhenPaused() public {
        vm.prank(admin);
        queue.pause();
        vm.prank(alice);
        vm.expectRevert();
        queue.submit(1000e6, 990e18);
    }

    function test_submit_incrementsOrderId() public {
        vm.prank(alice);
        uint256 id1 = queue.submit(1000e6, 990e18);
        vm.prank(bob);
        uint256 id2 = queue.submit(2000e6, 1980e18);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    // ---------------- cancel ----------------

    function test_cancel_refundsUsdc() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(alice);
        queue.cancel(id);

        ISubscriptionQueue.Order memory o = queue.orderOf(id);
        assertEq(uint8(o.status), uint8(ISubscriptionQueue.OrderStatus.Cancelled));
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        assertEq(queue.totalPendingUsdc(), 0);
    }

    function test_cancel_onlyOwner() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderOwnerOnly.selector, id));
        queue.cancel(id);
    }

    function test_cancel_evenWhenPaused() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(admin);
        queue.pause();
        // user can always exit even when queue is paused
        vm.prank(alice);
        queue.cancel(id);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_cancel_revertsIfAlreadyCancelled() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(alice);
        queue.cancel(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderAlreadyCancelled.selector, id));
        queue.cancel(id);
    }

    function test_cancel_revertsIfExecuted() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(operator);
        queue.execute(id, 1000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderAlreadyExecuted.selector, id));
        queue.cancel(id);
    }

    function test_cancel_revertsIfNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderNotFound.selector, 42));
        queue.cancel(42);
    }

    // ---------------- reclaimExpired ----------------

    function test_reclaimExpired_revertsBeforeExpiry() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderNotMature.selector, id));
        queue.reclaimExpired(id);
    }

    function test_reclaimExpired_callableByAnyone_refundsOwner() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(bob);
        queue.reclaimExpired(id);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        ISubscriptionQueue.Order memory o = queue.orderOf(id);
        assertEq(uint8(o.status), uint8(ISubscriptionQueue.OrderStatus.Expired));
    }

    // ---------------- execute ----------------

    function test_execute_mintsSharesAndForwardsUsdc() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(operator);
        queue.execute(id, 1000e18);

        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(usdy.balanceOf(address(vault)), 1000e18);
        assertEq(usdc.balanceOf(operatorTreasury), 1000e6);
        assertEq(queue.totalPendingUsdc(), 0);
        ISubscriptionQueue.Order memory o = queue.orderOf(id);
        assertEq(uint8(o.status), uint8(ISubscriptionQueue.OrderStatus.Executed));
    }

    function test_execute_revertsSlippage() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 1000e18);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.SlippageExceeded.selector, 999e18, 1000e18)
        );
        queue.execute(id, 999e18);
    }

    function test_execute_acceptsAtMinSharesExact() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 1000e18);
        vm.prank(operator);
        queue.execute(id, 1000e18);
        assertEq(vault.balanceOf(alice), 1000e18);
    }

    function test_execute_revertsExpired() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderExpired.selector, id));
        queue.execute(id, 1000e18);
    }

    function test_execute_onlyOperator() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(alice);
        vm.expectRevert();
        queue.execute(id, 1000e18);
    }

    function test_execute_revertsWhenPaused() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e6, 990e18);
        vm.prank(admin);
        queue.pause();
        vm.prank(operator);
        vm.expectRevert();
        queue.execute(id, 1000e18);
    }

    function test_batchExecute_processesMultipleOrders() public {
        vm.prank(alice);
        uint256 id1 = queue.submit(1000e6, 990e18);
        vm.prank(bob);
        uint256 id2 = queue.submit(2000e6, 1980e18);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint128[] memory amts = new uint128[](2);
        amts[0] = 1000e18;
        amts[1] = 2000e18;

        vm.prank(operator);
        queue.batchExecute(ids, amts);

        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(vault.balanceOf(bob), 2000e18);
        assertEq(usdc.balanceOf(operatorTreasury), 3000e6);
    }

    function test_batchExecute_revertsLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint128[] memory amts = new uint128[](1);
        vm.prank(operator);
        vm.expectRevert(TreasuryErrors.LengthMismatch.selector);
        queue.batchExecute(ids, amts);
    }

    // ---------------- admin ----------------

    function test_setExecutionWindow() public {
        vm.prank(admin);
        queue.setExecutionWindow(2 days);
        assertEq(queue.executionWindow(), 2 days);
    }

    function test_setOperatorTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(admin);
        queue.setOperatorTreasury(newT);
        assertEq(queue.operatorTreasury(), newT);
    }

    function test_setOperatorTreasury_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        queue.setOperatorTreasury(address(0));
    }
}
