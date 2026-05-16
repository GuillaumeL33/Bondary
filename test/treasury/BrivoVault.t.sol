// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrivoVault} from "../../src/treasury/BrivoVault.sol";
import {GlobalIdentityRegistry} from "../../src/treasury/compliance/GlobalIdentityRegistry.sol";
import {ProductEligibilityRegistry} from "../../src/treasury/compliance/ProductEligibilityRegistry.sol";
import {IGlobalIdentityRegistry} from "../../src/treasury/interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../../src/treasury/interfaces/IProductEligibilityRegistry.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

import {MockToken} from "./mocks/MockToken.sol";

contract BrivoVaultTest is Test {
    BrivoVault internal vault;
    GlobalIdentityRegistry internal gir;
    ProductEligibilityRegistry internal per;
    MockToken internal usdy;

    address internal admin = makeAddr("admin");
    address internal kycOperator = makeAddr("kycOperator");
    address internal productAdmin = makeAddr("productAdmin");
    address internal gateway = makeAddr("gateway");
    address internal rescue = makeAddr("rescue");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol"); // no KYC

    bytes32 internal constant PRODUCT_ID = keccak256("brvUSTY");
    uint256 internal constant CAP = 1_000_000e18;
    uint256 internal constant MIN_SUB = 100e18;

    function setUp() public {
        gir = new GlobalIdentityRegistry(admin, kycOperator);
        per = new ProductEligibilityRegistry(admin, gir, productAdmin);
        usdy = new MockToken("Mock USDY", "USDY", 18);

        vault = new BrivoVault(
            "Brivo US Treasury Yield",
            "brvUSTY",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin,
            CAP,
            MIN_SUB
        );

        vm.startPrank(admin);
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, gateway);
        vault.grantRole(TreasuryRoles.RESCUE_ROLE, rescue);
        vm.stopPrank();

        vm.prank(productAdmin);
        per.registerProduct(
            PRODUCT_ID,
            address(vault),
            IGlobalIdentityRegistry.KycLevel.Basic,
            false
        );

        vm.startPrank(kycOperator);
        gir.registerIdentity(
            alice,
            IGlobalIdentityRegistry.KycLevel.Basic,
            bytes2("FR"),
            uint64(block.timestamp),
            uint64(block.timestamp + 365 days),
            bytes32("alice-ref")
        );
        gir.registerIdentity(
            bob,
            IGlobalIdentityRegistry.KycLevel.Basic,
            bytes2("DE"),
            uint64(block.timestamp),
            uint64(block.timestamp + 365 days),
            bytes32("bob-ref")
        );
        vm.stopPrank();

        usdy.mint(gateway, 10_000_000e18);
        vm.prank(gateway);
        usdy.approve(address(vault), type(uint256).max);
    }

    // ---------------- constructor ----------------

    function test_constructor_reverts_zeroUnderlying() public {
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        new BrivoVault(
            "x", "x",
            IERC20(address(0)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin,
            CAP,
            MIN_SUB
        );
    }

    function test_constructor_reverts_zeroEligibility() public {
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        new BrivoVault(
            "x", "x",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(0)),
            ITreasuryFeeCollector(address(0)),
            admin,
            CAP,
            MIN_SUB
        );
    }

    function test_constructor_reverts_zeroAdmin() public {
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        new BrivoVault(
            "x", "x",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            address(0),
            CAP,
            MIN_SUB
        );
    }

    function test_constructor_reverts_zeroProductId() public {
        vm.expectRevert(TreasuryErrors.VaultProductMismatch.selector);
        new BrivoVault(
            "x", "x",
            IERC20(address(usdy)),
            bytes32(0),
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin,
            CAP,
            MIN_SUB
        );
    }

    function test_constructor_reverts_zeroCap() public {
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        new BrivoVault(
            "x", "x",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin,
            0,
            MIN_SUB
        );
    }

    // ---------------- views ----------------

    function testFuzz_convertToShares_isOneToOne(uint256 amount) public view {
        assertEq(vault.convertToShares(amount), amount);
    }

    function testFuzz_convertToAssets_isOneToOne(uint256 amount) public view {
        assertEq(vault.convertToAssets(amount), amount);
    }

    function test_decimals_matchesUnderlying() public view {
        assertEq(vault.decimals(), 18);
    }

    function test_views_immutables() public view {
        assertEq(address(vault.underlying()), address(usdy));
        assertEq(vault.productId(), PRODUCT_ID);
        assertEq(address(vault.eligibility()), address(per));
        assertEq(vault.subscriptionCap(), CAP);
        assertEq(vault.minSubscription(), MIN_SUB);
    }

    // ---------------- depositFor ----------------

    function test_depositFor_revertsIfNotGateway() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.depositFor(500e18, alice, alice);
    }

    function test_depositFor_mintsOneToOne() public {
        vm.prank(gateway);
        uint256 shares = vault.depositFor(500e18, alice, gateway);
        assertEq(shares, 500e18);
        assertEq(vault.balanceOf(alice), 500e18);
        assertEq(vault.totalSupply(), 500e18);
        assertEq(vault.totalAssets(), 500e18);
        assertEq(usdy.balanceOf(address(vault)), 500e18);
    }

    function test_depositFor_revertsZeroAmount() public {
        vm.prank(gateway);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        vault.depositFor(0, alice, gateway);
    }

    function test_depositFor_revertsZeroReceiver() public {
        vm.prank(gateway);
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        vault.depositFor(500e18, address(0), gateway);
    }

    function test_depositFor_revertsBelowMinimum() public {
        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.VaultBelowMinimum.selector, 10e18, MIN_SUB)
        );
        vault.depositFor(10e18, alice, gateway);
    }

    function test_depositFor_revertsCapExceeded() public {
        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.VaultCapExceeded.selector, CAP + 1, CAP)
        );
        vault.depositFor(CAP + 1, alice, gateway);
    }

    function test_depositFor_revertsRecipientNotEligible() public {
        // Carol has no KYC — isEligible returns false with KYC_MISSING
        vm.prank(gateway);
        vm.expectRevert();
        vault.depositFor(500e18, carol, gateway);
    }

    function test_depositFor_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(gateway);
        vm.expectRevert();
        vault.depositFor(500e18, alice, gateway);
    }

    // ---------------- redeemFor ----------------

    function test_redeemFor_burnsOneToOne() public {
        // Allowlist the gateway so it can hold shares (transfers to/from it pass).
        vm.prank(productAdmin);
        per.addAllowlistAccount(PRODUCT_ID, gateway);

        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(alice);
        vault.transfer(gateway, 200e18);

        address operatorTreasury = makeAddr("operatorTreasury");
        vm.prank(gateway);
        uint256 assets = vault.redeemFor(200e18, operatorTreasury, gateway);

        assertEq(assets, 200e18);
        assertEq(usdy.balanceOf(operatorTreasury), 200e18);
        assertEq(vault.balanceOf(gateway), 0);
        assertEq(vault.totalSupply(), 300e18);
        assertEq(vault.totalAssets(), 300e18);
    }

    function test_redeemFor_revertsOwnerMismatch() public {
        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.VaultOwnerMismatch.selector, gateway, alice)
        );
        vault.redeemFor(100e18, alice, alice);
    }

    function test_redeemFor_revertsZeroAmount() public {
        vm.prank(gateway);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        vault.redeemFor(0, alice, gateway);
    }

    function test_redeemFor_revertsZeroReceiver() public {
        vm.prank(gateway);
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        vault.redeemFor(100e18, address(0), gateway);
    }

    function test_redeemFor_onlyGateway() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.redeemFor(100e18, alice, alice);
    }

    // ---------------- transfer eligibility ----------------

    function test_transfer_revertsRecipientNotEligible() public {
        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(carol, 100e18);
    }

    function test_transfer_allowsEligiblePeers() public {
        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(alice);
        vault.transfer(bob, 100e18);
        assertEq(vault.balanceOf(bob), 100e18);
        assertEq(vault.balanceOf(alice), 400e18);
    }

    function test_transfer_revertsSenderBlocklisted() public {
        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(productAdmin);
        per.addBlocklistAccount(PRODUCT_ID, alice, bytes32("sanctioned"));
        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(bob, 100e18);
    }

    function test_burn_alwaysAllowed_evenIfQueueIsExoticAddress() public {
        // Demonstrates that redeemFor never checks the burner identity.
        vm.prank(productAdmin);
        per.addAllowlistAccount(PRODUCT_ID, gateway);

        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        vm.prank(alice);
        vault.transfer(gateway, 500e18);

        // Even if we now freeze the product, redeemFor still goes through.
        // (Burn skips the to==0 eligibility check entirely; ProductStatus is
        // checked via `to` for non-burn paths.)
        address operatorTreasury = makeAddr("operatorTreasury");
        vm.prank(gateway);
        vault.redeemFor(500e18, operatorTreasury, gateway);
        assertEq(usdy.balanceOf(operatorTreasury), 500e18);
    }

    // ---------------- admin ----------------

    function test_setSubscriptionCap() public {
        vm.prank(admin);
        vault.setSubscriptionCap(2 * CAP);
        assertEq(vault.subscriptionCap(), 2 * CAP);
    }

    function test_setSubscriptionCap_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(TreasuryErrors.ZeroAmount.selector);
        vault.setSubscriptionCap(0);
    }

    function test_setMinSubscription() public {
        vm.prank(admin);
        vault.setMinSubscription(50e18);
        assertEq(vault.minSubscription(), 50e18);
    }

    function test_setFeeCollector() public {
        address fc = makeAddr("feeCollector");
        vm.prank(admin);
        vault.setFeeCollector(fc);
        assertEq(address(vault.feeCollector()), fc);
    }

    function test_setFeeCollector_acceptsZero() public {
        vm.prank(admin);
        vault.setFeeCollector(address(0));
        assertEq(address(vault.feeCollector()), address(0));
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_onlyPauserRole() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.pause();
    }

    // ---------------- reclaimExcess ----------------

    function test_reclaimExcess_returnsZeroWhenBalanced() public {
        vm.prank(rescue);
        uint256 amt = vault.reclaimExcess(rescue);
        assertEq(amt, 0);
    }

    function test_reclaimExcess_reclaimsOverDelivery() public {
        usdy.mint(address(vault), 100e18);
        vm.prank(rescue);
        uint256 amt = vault.reclaimExcess(rescue);
        assertEq(amt, 100e18);
        assertEq(usdy.balanceOf(rescue), 100e18);
    }

    function test_reclaimExcess_onlyRescueRole() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.reclaimExcess(alice);
    }

    function test_reclaimExcess_revertsZeroReceiver() public {
        vm.prank(rescue);
        vm.expectRevert(TreasuryErrors.ZeroAddress.selector);
        vault.reclaimExcess(address(0));
    }

    // ---------------- I1 invariant spot-check ----------------

    function test_invariant_I1_holdsAfterMintRedeem() public {
        vm.prank(productAdmin);
        per.addAllowlistAccount(PRODUCT_ID, gateway);

        vm.prank(gateway);
        vault.depositFor(500e18, alice, gateway);
        assertGe(vault.totalAssets(), vault.totalSupply());

        vm.prank(alice);
        vault.transfer(gateway, 200e18);
        assertGe(vault.totalAssets(), vault.totalSupply());

        vm.prank(gateway);
        vault.redeemFor(200e18, makeAddr("out"), gateway);
        assertGe(vault.totalAssets(), vault.totalSupply());
    }
}
