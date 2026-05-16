// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrivoVault} from "../../src/treasury/BrivoVault.sol";
import {RedemptionQueue} from "../../src/treasury/RedemptionQueue.sol";
import {GlobalIdentityRegistry} from "../../src/treasury/compliance/GlobalIdentityRegistry.sol";
import {ProductEligibilityRegistry} from "../../src/treasury/compliance/ProductEligibilityRegistry.sol";
import {IGlobalIdentityRegistry} from "../../src/treasury/interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../../src/treasury/interfaces/IProductEligibilityRegistry.sol";
import {IRedemptionQueue} from "../../src/treasury/interfaces/IRedemptionQueue.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

import {MockToken} from "./mocks/MockToken.sol";

contract RedemptionQueueTest is Test {
    BrivoVault internal vault;
    RedemptionQueue internal queue;
    GlobalIdentityRegistry internal gir;
    ProductEligibilityRegistry internal per;
    MockToken internal usdc;
    MockToken internal usdy;

    address internal admin = makeAddr("admin");
    address internal kycOperator = makeAddr("kycOperator");
    address internal productAdmin = makeAddr("productAdmin");
    address internal operator = makeAddr("operator");
    address internal subGateway = makeAddr("subGateway"); // proxy for subscription queue in tests
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
            "brvUSTY", "brvUSTY",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin, 10_000_000e18, 100e18
        );

        queue = new RedemptionQueue(
            vault, IERC20(address(usdc)),
            admin, operator, WINDOW
        );

        vm.startPrank(admin);
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, address(queue));
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, subGateway);
        vm.stopPrank();

        vm.startPrank(productAdmin);
        per.registerProduct(PRODUCT_ID, address(vault), IGlobalIdentityRegistry.KycLevel.Basic, false);
        per.addAllowlistAccount(PRODUCT_ID, address(queue));
        per.addAllowlistAccount(PRODUCT_ID, subGateway);
        vm.stopPrank();

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

        // Fund operator with USDC
        usdc.mint(operator, 10_000_000e6);
        vm.prank(operator);
        usdc.approve(address(queue), type(uint256).max);

        // Seed alice + bob with brvUSTY through the subscription gateway proxy
        usdy.mint(subGateway, 10_000e18);
        vm.prank(subGateway);
        usdy.approve(address(vault), type(uint256).max);
        vm.prank(subGateway);
        vault.depositFor(5000e18, alice, subGateway);
        vm.prank(subGateway);
        vault.depositFor(5000e18, bob, subGateway);

        vm.prank(alice);
        IERC20(address(vault)).approve(address(queue), type(uint256).max);
        vm.prank(bob);
        IERC20(address(vault)).approve(address(queue), type(uint256).max);
    }

    // ---------------- submit ----------------

    function test_submit_escrowsShares() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);

        assertEq(id, 1);
        assertEq(vault.balanceOf(alice), 4000e18);
        assertEq(vault.balanceOf(address(queue)), 1000e18);
        assertEq(queue.totalPendingShares(), 1000e18);

        IRedemptionQueue.Order memory o = queue.orderOf(id);
        assertEq(uint8(o.status), uint8(IRedemptionQueue.OrderStatus.Pending));
        assertEq(o.user, alice);
        assertEq(o.sharesIn, 1000e18);
        assertEq(o.minUsdcOut, 990e6);
    }

    function test_submit_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        queue.submit(0, 990e6);

        vm.prank(alice);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        queue.submit(1000e18, 0);
    }

    function test_submit_revertsWhenPaused() public {
        vm.prank(admin);
        queue.pause();
        vm.prank(alice);
        vm.expectRevert();
        queue.submit(1000e18, 990e6);
    }

    // ---------------- cancel ----------------

    function test_cancel_returnsShares() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(alice);
        queue.cancel(id);
        assertEq(vault.balanceOf(alice), 5000e18);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(queue.totalPendingShares(), 0);
    }

    function test_cancel_onlyOwner() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderOwnerOnly.selector, id));
        queue.cancel(id);
    }

    function test_cancel_evenWhenPaused() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(admin);
        queue.pause();
        vm.prank(alice);
        queue.cancel(id);
        assertEq(vault.balanceOf(alice), 5000e18);
    }

    // ---------------- reclaimExpired ----------------

    function test_reclaimExpired_afterExpiry() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.warp(block.timestamp + WINDOW + 1);
        queue.reclaimExpired(id);
        assertEq(vault.balanceOf(alice), 5000e18);
    }

    function test_reclaimExpired_revertsBeforeExpiry() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderNotMature.selector, id));
        queue.reclaimExpired(id);
    }

    // ---------------- execute ----------------

    function test_execute_burnsSharesAndPaysUsdc() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(operator);
        queue.execute(id, 1000e6);

        assertEq(vault.balanceOf(alice), 4000e18);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(vault.totalSupply(), 9000e18);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdy.balanceOf(operator), 1000e18);
        assertEq(queue.totalPendingShares(), 0);
    }

    function test_execute_revertsSlippage() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 1000e6);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.SlippageExceeded.selector, 999e6, 1000e6)
        );
        queue.execute(id, 999e6);
    }

    function test_execute_revertsExpired() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TreasuryErrors.OrderExpired.selector, id));
        queue.execute(id, 1000e6);
    }

    function test_execute_onlyOperator() public {
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(alice);
        vm.expectRevert();
        queue.execute(id, 1000e6);
    }

    function test_execute_evenIfUserGetsBlocklistedLater() public {
        // alice submits, then gets blocklisted; queue should still execute
        // because burn skips eligibility on the from side (queue is the holder).
        vm.prank(alice);
        uint256 id = queue.submit(1000e18, 990e6);
        vm.prank(productAdmin);
        per.addBlocklistAccount(PRODUCT_ID, alice, bytes32("sanctioned"));
        vm.prank(operator);
        queue.execute(id, 1000e6);
        // alice gets USDC even though she's blocklisted (off-chain settlement)
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_batchExecute() public {
        vm.prank(alice);
        uint256 id1 = queue.submit(1000e18, 990e6);
        vm.prank(bob);
        uint256 id2 = queue.submit(2000e18, 1980e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1; ids[1] = id2;
        uint128[] memory amts = new uint128[](2);
        amts[0] = 1000e6; amts[1] = 2000e6;

        vm.prank(operator);
        queue.batchExecute(ids, amts);

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 2000e6);
        assertEq(usdy.balanceOf(operator), 3000e18);
        assertEq(vault.totalSupply(), 7000e18);
    }

    // ---------------- admin ----------------

    function test_setExecutionWindow() public {
        vm.prank(admin);
        queue.setExecutionWindow(2 days);
        assertEq(queue.executionWindow(), 2 days);
    }

    function test_setExecutionWindow_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        queue.setExecutionWindow(2 days);
    }
}
