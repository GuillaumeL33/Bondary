// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CorporateBond} from "../src/CorporateBond.sol";
import {BondFactory} from "../src/BondFactory.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title MarketplaceTest
 * @notice Tests pour BondaryMarketplace (order book secondaire).
 *
 *  Setup :
 *    - 1 bond COUPON activé, alice détient 500 bonds, bob 300 bonds
 *    - alice crée un ordre de vente → charlie achète
 *    - Tests de frais, pénalité sortie anticipée, annulation, KYC
 */
contract MarketplaceTest is Test {
    // ─── Actors ──────────────────────────────────────────────────────────────
    address admin   = makeAddr("admin");
    address issuer  = makeAddr("issuer");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie"); // buyer (gets KYC'd in setUp)
    address dave    = makeAddr("dave");    // no KYC

    // ─── Contracts ───────────────────────────────────────────────────────────
    ERC20Mock           usdc;
    ComplianceManager   compliance;
    BondaryFeeCollector feeCollector;
    BondFactory         factory;
    BondaryMarketplace  marketplace;
    CorporateBond       bond;

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 constant FACE_VALUE       = 1_000e6;
    uint256 constant TOTAL_ISSUANCE   = 1_000;
    uint256 constant SOFT_CAP         = 800;
    uint256 constant SETUP_FEE_BPS    = 100;
    uint256 constant COUPON_FEE_BPS   = 50;
    uint256 constant TRADING_FEE_BPS  = 50;   // 0.5%
    uint256 constant PENALTY_BPS      = 200;  // 2.0%

    uint256 subscriptionEnd;
    uint256 maturityDate;

    // ─── setUp ───────────────────────────────────────────────────────────────

    function setUp() public {
        subscriptionEnd = block.timestamp + 7 days;
        maturityDate    = block.timestamp + 365 days;

        usdc = new ERC20Mock();

        compliance   = new ComplianceManager(admin);
        feeCollector = new BondaryFeeCollector(admin);

        CorporateBond impl = new CorporateBond();
        factory = new BondFactory(admin, address(impl), address(compliance), address(feeCollector));

        marketplace = new BondaryMarketplace(
            admin,
            address(compliance),
            address(feeCollector),
            address(factory),
            TRADING_FEE_BPS,
            PENALTY_BPS
        );

        // KYC all participants
        vm.startPrank(admin);
        compliance.whitelist(alice);
        compliance.whitelist(bob);
        compliance.whitelist(charlie);
        compliance.whitelist(issuer);
        // Grant factory DEFAULT_ADMIN_ROLE on feeCollector so it can auto-grant
        // AUTHORIZED_SOURCE_ROLE to each bond it creates
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), address(factory));
        // Grant marketplace AUTHORIZED_SOURCE_ROLE so it can notify fees
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), address(marketplace));
        vm.stopPrank();

        // Create bond through factory
        CorporateBond.BondTerms memory terms = CorporateBond.BondTerms({
            faceValue:           FACE_VALUE,
            totalIssuance:       TOTAL_ISSUANCE,
            softCap:             SOFT_CAP,
            issuancePrice:       FACE_VALUE,
            minInvestment:       FACE_VALUE,
            couponRate:          800,
            maturityDate:        maturityDate,
            couponFrequency:     90 days,
            paymentMode:         CorporateBond.PaymentMode.COUPON,
            earlyBuybackEnabled: true,
            subscriptionEnd:     subscriptionEnd,
            paymentToken:        address(usdc),
            issuer:              issuer
        });

        vm.prank(admin);
        address bondAddr = factory.createBond(
            "Test Bond", "TB", terms, SETUP_FEE_BPS, COUPON_FEE_BPS, admin
        );
        bond = CorporateBond(bondAddr);

        // Whitelist marketplace (holds bonds during escrow)
        vm.prank(admin);
        compliance.whitelist(address(marketplace));

        // Alice and bob subscribe
        uint256 aliceCost = 500 * FACE_VALUE;
        uint256 bobCost   = 300 * FACE_VALUE;
        usdc.mint(alice, aliceCost);
        usdc.mint(bob,   bobCost);

        vm.startPrank(alice);
        usdc.approve(address(bond), aliceCost);
        bond.subscribe(500);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(bond), bobCost);
        bond.subscribe(300);
        vm.stopPrank();

        // Activate bond
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        bond.activateBond();

        // Claim allocations
        vm.prank(alice);
        bond.claimAllocation();
        vm.prank(bob);
        bond.claimAllocation();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  1. CREATE SELL ORDER
    // ─────────────────────────────────────────────────────────────────────────

    function test_CreateSellOrder_Success() public {
        uint256 pricePerBond = 1_050e6; // 1050 USDC per bond

        vm.startPrank(alice);
        bond.approve(address(marketplace), 100);
        uint256 orderId = marketplace.createSellOrder(address(bond), 100, pricePerBond);
        vm.stopPrank();

        BondaryMarketplace.Order memory order = marketplace.getOrder(orderId);
        assertEq(order.bond,         address(bond));
        assertEq(order.seller,       alice);
        assertEq(order.bondAmount,   100);
        assertEq(order.pricePerBond, pricePerBond);
        assertTrue(order.active);

        // Bonds are escrowed in marketplace
        assertEq(bond.balanceOf(address(marketplace)), 100);
        assertEq(bond.balanceOf(alice), 400);
    }

    function test_CreateSellOrder_RevertIfNotOfficialBond() public {
        address fakeBond = makeAddr("fakeBond");
        vm.prank(alice);
        vm.expectRevert("Marketplace: not official bond");
        marketplace.createSellOrder(fakeBond, 10, FACE_VALUE);
    }

    function test_CreateSellOrder_RevertIfNotCompliant() public {
        vm.prank(dave); // not KYC'd
        vm.expectRevert("Marketplace: seller not compliant");
        marketplace.createSellOrder(address(bond), 10, FACE_VALUE);
    }

    function test_CreateSellOrder_RevertIfInsufficientBonds() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 1000);
        vm.expectRevert("Marketplace: insufficient bonds");
        marketplace.createSellOrder(address(bond), 600, FACE_VALUE); // alice has 500
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  2. FILL ORDER (avec pénalité — bond encore ACTIVE)
    // ─────────────────────────────────────────────────────────────────────────

    function test_FillOrder_WithEarlyExitPenalty() public {
        uint256 pricePerBond = 1_050e6;
        uint256 bondAmount   = 100;

        vm.startPrank(alice);
        bond.approve(address(marketplace), bondAmount);
        uint256 orderId = marketplace.createSellOrder(address(bond), bondAmount, pricePerBond);
        vm.stopPrank();

        uint256 totalCost    = bondAmount * pricePerBond;
        uint256 tradingFee   = totalCost * TRADING_FEE_BPS / 10_000;
        uint256 penaltyFee   = totalCost * PENALTY_BPS / 10_000;
        uint256 totalFees    = tradingFee + penaltyFee;

        usdc.mint(charlie, totalCost);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        // Charlie receives bonds
        assertEq(bond.balanceOf(charlie), bondAmount);
        // Alice receives net amount
        // (note: alice had her balance from the subscription. setUp() minted exact amounts)
        // Alice net receive = totalCost - tradingFee - penaltyFee
        // Check order is inactive
        assertFalse(marketplace.getOrder(orderId).active);
        // FeeCollector received fees
        assertGt(usdc.balanceOf(address(feeCollector)), 0);
        // Verify fee amounts in feeCollector
        // (setup fee was already in feeCollector from activation; add new fees)
        uint256 fcBalance = usdc.balanceOf(address(feeCollector));
        uint256 setupFee  = (800 * FACE_VALUE) * SETUP_FEE_BPS / 10_000;
        assertEq(fcBalance, setupFee + totalFees);
    }

    function test_FillOrder_NoEarlyExitPenalty_AtMaturity() public {
        // Warp past maturity and signal it
        vm.warp(maturityDate + 1);
        bond.signalMaturity();

        uint256 pricePerBond = 1_000e6;
        uint256 bondAmount   = 50;

        vm.startPrank(alice);
        bond.approve(address(marketplace), bondAmount);
        uint256 orderId = marketplace.createSellOrder(address(bond), bondAmount, pricePerBond);
        vm.stopPrank();

        uint256 totalCost  = bondAmount * pricePerBond;
        uint256 tradingFee = totalCost * TRADING_FEE_BPS / 10_000;
        // No penalty because state is MATURED

        usdc.mint(charlie, totalCost);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        assertEq(bond.balanceOf(charlie), bondAmount);

        uint256 setupFee = (800 * FACE_VALUE) * SETUP_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(address(feeCollector)), setupFee + tradingFee);
    }

    function test_FillOrder_RevertIfBuyerNotCompliant() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 50);
        uint256 orderId = marketplace.createSellOrder(address(bond), 50, FACE_VALUE);
        vm.stopPrank();

        uint256 cost = 50 * FACE_VALUE;
        usdc.mint(dave, cost);
        vm.startPrank(dave);
        usdc.approve(address(marketplace), cost);
        vm.expectRevert("Marketplace: buyer not compliant");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_FillOrder_RevertIfSellerNotCompliant() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 50);
        uint256 orderId = marketplace.createSellOrder(address(bond), 50, FACE_VALUE);
        vm.stopPrank();

        vm.prank(admin);
        compliance.revoke(alice);

        uint256 cost = 50 * FACE_VALUE;
        usdc.mint(charlie, cost);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), cost);
        vm.expectRevert("Marketplace: seller not compliant");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_FillOrder_RevertIfSelfTrade() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 50);
        uint256 orderId = marketplace.createSellOrder(address(bond), 50, FACE_VALUE);
        vm.stopPrank();

        uint256 cost = 50 * FACE_VALUE;
        usdc.mint(alice, cost);
        vm.startPrank(alice);
        usdc.approve(address(marketplace), cost);
        vm.expectRevert("Marketplace: self-trade");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_FillOrder_RevertIfAlreadyFilled() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 50);
        uint256 orderId = marketplace.createSellOrder(address(bond), 50, FACE_VALUE);
        vm.stopPrank();

        uint256 cost = 50 * FACE_VALUE;
        usdc.mint(charlie, cost * 2);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), cost * 2);
        marketplace.fillOrder(orderId);
        vm.expectRevert("Marketplace: order not active");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3. CANCEL ORDER
    // ─────────────────────────────────────────────────────────────────────────

    function test_CancelOrder_BySeller() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 100);
        uint256 orderId = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        vm.stopPrank();

        assertEq(bond.balanceOf(alice), 400);

        vm.prank(alice);
        marketplace.cancelOrder(orderId);

        // Bonds returned to alice
        assertEq(bond.balanceOf(alice), 500);
        assertFalse(marketplace.getOrder(orderId).active);
    }

    function test_CancelOrder_ByAdmin() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 100);
        uint256 orderId = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        vm.stopPrank();

        vm.prank(admin);
        marketplace.cancelOrder(orderId);

        assertEq(bond.balanceOf(alice), 500);
    }

    function test_CancelOrder_RevertIfNotAuthorized() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 100);
        uint256 orderId = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        vm.stopPrank();

        vm.prank(charlie);
        vm.expectRevert("Marketplace: not authorized");
        marketplace.cancelOrder(orderId);
    }

    function test_CancelOrder_RevertIfAlreadyCancelled() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 100);
        uint256 orderId = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        vm.stopPrank();

        vm.prank(alice);
        marketplace.cancelOrder(orderId);

        vm.prank(alice);
        vm.expectRevert("Marketplace: order not active");
        marketplace.cancelOrder(orderId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  4. ADMIN FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function test_UpdateFees() public {
        vm.prank(admin);
        marketplace.updateFees(100, 300);

        assertEq(marketplace.tradingFeeBps(), 100);
        assertEq(marketplace.earlyExitPenaltyBps(), 300);
    }

    function test_UpdateFees_RevertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: trading fee too high");
        marketplace.updateFees(1_001, 200);
    }

    function test_UpdateFees_RevertIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        marketplace.updateFees(100, 200);
    }

    function test_Pause_BlocksCreateOrder() public {
        vm.prank(admin);
        marketplace.pause();

        vm.startPrank(alice);
        bond.approve(address(marketplace), 10);
        vm.expectRevert();
        marketplace.createSellOrder(address(bond), 10, FACE_VALUE);
        vm.stopPrank();
    }

    function test_Pause_BlocksFillOrder() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 10);
        uint256 orderId = marketplace.createSellOrder(address(bond), 10, FACE_VALUE);
        vm.stopPrank();

        vm.prank(admin);
        marketplace.pause();

        usdc.mint(charlie, 10 * FACE_VALUE);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), 10 * FACE_VALUE);
        vm.expectRevert();
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  5. BOND FACTORY REGISTRY
    // ─────────────────────────────────────────────────────────────────────────

    function test_Factory_IsOfficialBond() public view {
        assertTrue(factory.isOfficialBond(address(bond)));
    }

    function test_Factory_IsOfficialBond_False_ForRandom() public {
        address random = makeAddr("random");
        assertFalse(factory.isOfficialBond(random));
    }

    function test_Factory_BondCount() public view {
        assertEq(factory.bondCount(), 1);
    }

    function test_Factory_AllBonds() public view {
        address[] memory bonds = factory.allBonds();
        assertEq(bonds.length, 1);
        assertEq(bonds[0], address(bond));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  6. NEXT ORDER ID
    // ─────────────────────────────────────────────────────────────────────────

    function test_NextOrderId_Increments() public {
        vm.startPrank(alice);
        bond.approve(address(marketplace), 200);
        uint256 id0 = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        uint256 id1 = marketplace.createSellOrder(address(bond), 100, FACE_VALUE);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(marketplace.nextOrderId(), 2);
    }
}
