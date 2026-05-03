// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CorporateBond} from "../src/CorporateBond.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title CorporateBondTest
 * @notice Full lifecycle tests for CorporateBond.
 *
 *  Setup global :
 *    - admin     : Bondary team wallet
 *    - issuer    : corporate borrower
 *    - alice/bob : KYC'd investors
 *    - charlie   : non-KYC'd address
 *    - USDC mock : 6 decimals
 *
 *  Bond par défaut (mode COUPON) :
 *    - totalIssuance = 1_000 bonds
 *    - softCap       = 800 bonds
 *    - issuancePrice = 1_000e6 USDC par bond
 *    - faceValue     = 1_000e6 USDC par bond
 *    - couponRate    = 800 BPS (8% annuel)
 *    - couponFreq    = 90 days (trimestriel)
 *    - maturity      = 365 days
 *    - subscriptionEnd = 7 days
 */
contract CorporateBondTest is Test {
    // ─── Actors ──────────────────────────────────────────────────────────────
    address admin   = makeAddr("admin");
    address issuer  = makeAddr("issuer");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie"); // not KYC'd

    // ─── Contracts ───────────────────────────────────────────────────────────
    ERC20Mock           usdc;
    ComplianceManager   compliance;
    BondaryFeeCollector feeCollector;
    CorporateBond       impl;
    CorporateBond       bond; // proxy

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 constant FACE_VALUE      = 1_000e6;   // 1 000 USDC par bond
    uint256 constant TOTAL_ISSUANCE  = 1_000;
    uint256 constant SOFT_CAP        = 800;
    uint256 constant COUPON_RATE_BPS = 800;        // 8%
    uint256 constant COUPON_FREQ     = 90 days;
    uint256 constant SETUP_FEE_BPS   = 100;        // 1%
    uint256 constant COUPON_FEE_BPS  = 50;         // 0.5%

    uint256 subscriptionEnd;
    uint256 maturityDate;

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _makeBondTerms(CorporateBond.PaymentMode mode)
        internal
        view
        returns (CorporateBond.BondTerms memory)
    {
        return CorporateBond.BondTerms({
            faceValue:          FACE_VALUE,
            totalIssuance:      TOTAL_ISSUANCE,
            softCap:            SOFT_CAP,
            issuancePrice:      FACE_VALUE,
            minInvestment:      FACE_VALUE, // 1 bond minimum
            couponRate:         COUPON_RATE_BPS,
            maturityDate:       maturityDate,
            couponFrequency:    COUPON_FREQ,
            paymentMode:        mode,
            earlyBuybackEnabled: true,
            subscriptionEnd:    subscriptionEnd,
            paymentToken:       address(usdc),
            issuer:             issuer
        });
    }

    function _deployBond(CorporateBond.PaymentMode mode) internal returns (CorporateBond) {
        bytes memory initData = abi.encodeCall(
            CorporateBond.initialize,
            (
                "Bondary Test Bond",
                "BTB",
                _makeBondTerms(mode),
                SETUP_FEE_BPS,
                COUPON_FEE_BPS,
                address(compliance),
                address(feeCollector),
                admin
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        CorporateBond b = CorporateBond(address(proxy));
        // Grant AUTHORIZED_SOURCE_ROLE so bond can call feeCollector.notifyFeeReceived()
        vm.startPrank(admin);
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), address(b));
        vm.stopPrank();
        return b;
    }

    // Subscribe bondAmount bonds for investor from their wallet
    function _subscribe(CorporateBond b, address investor, uint256 bondAmount) internal {
        uint256 cost = bondAmount * FACE_VALUE;
        usdc.mint(investor, cost);
        vm.startPrank(investor);
        usdc.approve(address(b), cost);
        b.subscribe(bondAmount);
        vm.stopPrank();
    }

    // Activate the bond as admin
    function _activate(CorporateBond b) internal {
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        b.activateBond();
    }

    // ─── setUp ───────────────────────────────────────────────────────────────

    function setUp() public {
        subscriptionEnd = block.timestamp + 7 days;
        maturityDate    = block.timestamp + 365 days;

        // Tokens
        usdc = new ERC20Mock();

        // Infrastructure
        compliance   = new ComplianceManager(admin);
        feeCollector = new BondaryFeeCollector(admin);
        impl         = new CorporateBond();

        // KYC whitelist
        vm.startPrank(admin);
        compliance.whitelist(alice);
        compliance.whitelist(bob);
        compliance.whitelist(issuer);
        vm.stopPrank();

        // Deploy default COUPON bond
        bond = _deployBond(CorporateBond.PaymentMode.COUPON);

        vm.startPrank(admin);
        // Whitelist bond contract (compliance check on mint passes for address(0)→bond)
        compliance.whitelist(address(bond));
        // Grant bond AUTHORIZED_SOURCE_ROLE so it can call feeCollector.notifyFeeReceived()
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), address(bond));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  1. SUBSCRIPTION TESTS
    // ─────────────────────────────────────────────────────────────────────────

    function test_Subscribe_Success() public {
        _subscribe(bond, alice, 100);
        assertEq(bond.subscriptions(alice), 100);
        assertEq(bond.totalSubscribed(), 100);
        assertEq(usdc.balanceOf(address(bond)), 100 * FACE_VALUE);
    }

    function test_Subscribe_MultipleInvestors() public {
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   300);
        assertEq(bond.totalSubscribed(), 800);
        assertEq(usdc.balanceOf(address(bond)), 800 * FACE_VALUE);
    }

    function test_Subscribe_RevertIfNotCompliant() public {
        uint256 cost = 1 * FACE_VALUE;
        usdc.mint(charlie, cost);
        vm.startPrank(charlie);
        usdc.approve(address(bond), cost);
        vm.expectRevert("Bond: not compliant");
        bond.subscribe(1);
        vm.stopPrank();
    }

    function test_Subscribe_RevertAfterSubscriptionEnd() public {
        vm.warp(subscriptionEnd + 1);
        uint256 cost = FACE_VALUE;
        usdc.mint(alice, cost);
        vm.startPrank(alice);
        usdc.approve(address(bond), cost);
        vm.expectRevert("Bond: subscription ended");
        bond.subscribe(1);
        vm.stopPrank();
    }

    function test_Subscribe_ClampToHardCap() public {
        // Alice tries to subscribe 900 but only 1000 total remain → all assigned
        _subscribe(bond, alice, 900);
        // Bob tries 200 but only 100 left
        uint256 cost = 200 * FACE_VALUE;
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(address(bond), cost);
        bond.subscribe(200); // clamped to 100
        vm.stopPrank();
        assertEq(bond.totalSubscribed(), TOTAL_ISSUANCE);
        assertEq(bond.subscriptions(bob), 100);
    }

    function test_CancelSubscription() public {
        _subscribe(bond, alice, 100);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        bond.cancelSubscription();

        assertEq(bond.subscriptions(alice), 0);
        assertEq(bond.totalSubscribed(), 0);
        assertEq(usdc.balanceOf(alice), balBefore + 100 * FACE_VALUE);
    }

    function test_CancelSubscription_RevertIfNone() public {
        vm.prank(alice);
        vm.expectRevert("Bond: no subscription");
        bond.cancelSubscription();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  2. ACTIVATION TESTS
    // ─────────────────────────────────────────────────────────────────────────

    function test_ActivateBond_Success() public {
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   400);
        _activate(bond);

        assertEq(uint8(bond.state()), uint8(CorporateBond.State.ACTIVE));
        // Setup fee deducted from raised amount
        uint256 raised   = 900 * FACE_VALUE;
        uint256 setupFee = raised * SETUP_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(address(feeCollector)), setupFee);
        assertEq(usdc.balanceOf(issuer), raised - setupFee);
    }

    function test_ActivateBond_RevertIfSoftCapNotReached() public {
        _subscribe(bond, alice, 500); // below 800 soft cap
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vm.expectRevert("Bond: soft cap not reached");
        bond.activateBond();
    }

    function test_ActivateBond_RevertIfSubscriptionStillOpen() public {
        _subscribe(bond, alice, 900);
        // Don't warp past subscriptionEnd and don't hit hard cap
        vm.prank(admin);
        vm.expectRevert("Bond: subscription still open");
        bond.activateBond();
    }

    function test_ActivateBond_ImmediatelyIfHardCapReached() public {
        // Hard cap = 1000 bonds, trigger activation before subscriptionEnd
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   500);
        // No time warp needed — hard cap triggers immediate eligibility
        vm.prank(admin);
        bond.activateBond();
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.ACTIVE));
    }

    function test_FailBond() public {
        _subscribe(bond, alice, 500); // below soft cap
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        bond.failBond();
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.FAILED));
    }

    function test_FailBond_RevertIfSoftCapReached() public {
        _subscribe(bond, alice, 900);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vm.expectRevert("Bond: soft cap reached");
        bond.failBond();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3. CLAIM ALLOCATION & REFUND
    // ─────────────────────────────────────────────────────────────────────────

    function test_ClaimAllocation() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();

        assertEq(bond.balanceOf(alice), 900);
        assertTrue(bond.allocationClaimed(alice));
    }

    function test_ClaimAllocation_RevertIfAlreadyClaimed() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();

        vm.prank(alice);
        vm.expectRevert("Bond: already claimed");
        bond.claimAllocation();
    }

    function test_ClaimRefund_AfterFailure() public {
        _subscribe(bond, alice, 100);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        bond.failBond();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bond.claimRefund();

        assertEq(usdc.balanceOf(alice), balBefore + 100 * FACE_VALUE);
        assertEq(bond.paymentDeposited(alice), 0);
    }

    function test_ClaimRefund_RevertIfNotFailed() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.prank(alice);
        vm.expectRevert("Bond: invalid state");
        bond.claimRefund();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  4. COUPON PAYMENT TESTS
    // ─────────────────────────────────────────────────────────────────────────

    function test_PayCoupon_Success() public {
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   300);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation(); // 500 bonds

        vm.prank(bob);
        bond.claimAllocation(); // 300 bonds

        // Fast-forward to first coupon date
        vm.warp(bond.nextCouponDate());

        uint256 couponAmount = bond.expectedCouponAmount();
        // Platform fee = 0.5% of couponAmount (taken from gross)
        // issuer pays net coupon + platform fee
        uint256 platformFee = couponAmount * COUPON_FEE_BPS / 10_000;
        uint256 netCoupon   = couponAmount - platformFee;

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        bond.payCoupon();
        vm.stopPrank();

        assertEq(bond.couponsPaid(), 1);
        assertGt(bond.totalCouponPerToken(), 0);
    }

    function test_PayCoupon_RevertIfNotDue() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();

        uint256 couponAmount = bond.expectedCouponAmount();

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        vm.expectRevert("Bond: coupon not due");
        bond.payCoupon();
        vm.stopPrank();
    }

    function test_ClaimCoupons_ProportionalToHolding() public {
        _subscribe(bond, alice, 600); // 60%
        _subscribe(bond, bob,   200); // 20% (800 total)
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();
        vm.prank(bob);
        bond.claimAllocation();

        vm.warp(bond.nextCouponDate());

        uint256 couponAmount = bond.expectedCouponAmount();
        uint256 platformFee  = couponAmount * COUPON_FEE_BPS / 10_000;
        uint256 netCoupon    = couponAmount - platformFee;

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        bond.payCoupon();
        vm.stopPrank();

        // Alice holds 600/800 = 75% of supply
        uint256 alicePending = bond.pendingCoupons(alice);
        uint256 bobPending   = bond.pendingCoupons(bob);
        // 600 bonds / 800 total → alice gets 75% of net coupon
        assertApproxEqAbs(alicePending, (netCoupon * 600) / 800, 1);
        assertApproxEqAbs(bobPending,   (netCoupon * 200) / 800, 1);
    }

    function test_ClaimCoupons_WithdrawsFunds() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();

        vm.warp(bond.nextCouponDate());

        uint256 couponAmount = bond.expectedCouponAmount();
        uint256 platformFee  = couponAmount * COUPON_FEE_BPS / 10_000;
        uint256 netCoupon    = couponAmount - platformFee;

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        bond.payCoupon();
        vm.stopPrank();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bond.claimCoupons();
        uint256 gained = usdc.balanceOf(alice) - balBefore;

        assertEq(gained, netCoupon); // alice holds 100% of supply
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  5. RETROACTIVE COUPON ON LATE ALLOCATION CLAIM
    // ─────────────────────────────────────────────────────────────────────────

    function test_RetroactiveCoupon_LateClaimGetsAllCoupons() public {
        // Alice subscribes, bob subscribes.
        // Only alice claims allocation → coupon paid → bob claims allocation late.
        // Bob should receive ALL coupons retroactively.
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   500);
        _activate(bond);

        // Only alice claims at activation
        vm.prank(alice);
        bond.claimAllocation();

        // First coupon paid (only alice in circulation at this point)
        vm.warp(bond.nextCouponDate());
        uint256 couponAmount = bond.expectedCouponAmount();
        uint256 platformFee  = couponAmount * COUPON_FEE_BPS / 10_000;
        uint256 netCoupon    = couponAmount - platformFee;

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        bond.payCoupon();
        vm.stopPrank();

        // Bob claims allocation late (after first coupon was paid)
        vm.prank(bob);
        bond.claimAllocation();

        // Bob should have retroactive credit for all coupons since activation
        uint256 bobPending = bond.pendingCoupons(bob);
        // totalCouponPerToken was set based on 500 bonds (alice only)
        // So totalCouponPerToken = netCoupon * 1e18 / 500
        // Bob gets 500 * totalCouponPerToken / 1e18 = netCoupon
        assertEq(bobPending, netCoupon);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  6. COUPON ACCRUAL ON TRANSFER
    // ─────────────────────────────────────────────────────────────────────────

    function test_CouponAccrual_OnTransfer() public {
        _subscribe(bond, alice, 500);
        _subscribe(bond, bob,   500);
        _activate(bond);

        vm.prank(alice);
        bond.claimAllocation();
        vm.prank(bob);
        bond.claimAllocation();

        // Pay first coupon
        vm.warp(bond.nextCouponDate());
        uint256 couponAmount = bond.expectedCouponAmount();
        uint256 platformFee  = couponAmount * COUPON_FEE_BPS / 10_000;
        uint256 netCoupon    = couponAmount - platformFee;

        usdc.mint(issuer, couponAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bond), couponAmount);
        bond.payCoupon();
        vm.stopPrank();

        // Alice's pending coupons before transfer: 500/1000 = 50%
        uint256 alicePendingBefore = bond.pendingCoupons(alice);
        assertApproxEqAbs(alicePendingBefore, netCoupon / 2, 1);

        // Alice transfers 200 bonds to bob (compliance: both whitelisted, bond contract whitelisted)
        vm.prank(alice);
        bond.transfer(bob, 200);

        // Alice's pending should have been crystallized before balance changed
        assertApproxEqAbs(bond.pendingCoupons(alice), netCoupon / 2, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  7. MATURITY / BULLET MODE
    // ─────────────────────────────────────────────────────────────────────────

    function test_BulletRepay_AndRedeem() public {
        CorporateBond bulletBond = _deployBond(CorporateBond.PaymentMode.BULLET);
        vm.prank(admin);
        compliance.whitelist(address(bulletBond));

        _subscribe(bulletBond, alice, 900);

        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        bulletBond.activateBond();

        vm.prank(alice);
        bulletBond.claimAllocation();

        // Warp to maturity
        vm.warp(maturityDate + 1);

        uint256 repayAmount = bulletBond.expectedBulletRepayment();

        usdc.mint(issuer, repayAmount);
        vm.startPrank(issuer);
        usdc.approve(address(bulletBond), repayAmount);
        bulletBond.repayBullet();
        vm.stopPrank();

        assertEq(uint8(bulletBond.state()), uint8(CorporateBond.State.MATURED));
        assertGt(bulletBond.redemptionRate(), 0);

        // Alice redeems
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bulletBond.redeemBonds(900);

        assertGt(usdc.balanceOf(alice), balBefore);
        assertEq(bulletBond.totalSupply(), 0);
        assertEq(uint8(bulletBond.state()), uint8(CorporateBond.State.CLOSED));
    }

    function test_SignalMaturity() public {
        _subscribe(bond, alice, 900);
        _activate(bond);

        vm.warp(maturityDate + 1);
        bond.signalMaturity(); // anyone can call
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.MATURED));
    }

    function test_SignalMaturity_RevertIfNotMatured() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.expectRevert("Bond: not matured");
        bond.signalMaturity();
    }

    function test_RepayPrincipal_CouponMode() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        vm.warp(maturityDate + 1);

        uint256 principal = 900 * FACE_VALUE;
        usdc.mint(issuer, principal);
        vm.startPrank(issuer);
        usdc.approve(address(bond), principal);
        bond.repayPrincipal();
        vm.stopPrank();

        assertEq(uint8(bond.state()), uint8(CorporateBond.State.MATURED));

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bond.redeemBonds(900);
        assertEq(usdc.balanceOf(alice) - balBefore, principal);
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.CLOSED));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  8. PARTIAL REDEMPTION
    // ─────────────────────────────────────────────────────────────────────────

    function test_PartialRedemption() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        vm.warp(maturityDate + 1);

        uint256 principal = 900 * FACE_VALUE;
        usdc.mint(issuer, principal);
        vm.startPrank(issuer);
        usdc.approve(address(bond), principal);
        bond.repayPrincipal();
        vm.stopPrank();

        // Redeem 400 first
        vm.prank(alice);
        bond.redeemBonds(400);
        assertEq(bond.balanceOf(alice), 500);
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.MATURED)); // still MATURED

        // Redeem remaining 500
        vm.prank(alice);
        bond.redeemBonds(500);
        assertEq(bond.totalSupply(), 0);
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.CLOSED));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  9. EARLY BUYBACK
    // ─────────────────────────────────────────────────────────────────────────

    function test_EarlyBuyback() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        // Issuer opens buyback at 950 USDC per bond
        uint256 ratePerBond = 950e6;
        uint256 totalFunds  = 100 * ratePerBond;
        usdc.mint(issuer, totalFunds);
        vm.startPrank(issuer);
        usdc.approve(address(bond), totalFunds);
        bond.openEarlyBuyback(totalFunds, ratePerBond);
        vm.stopPrank();

        assertEq(bond.earlyBuybackPool(), totalFunds);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bond.redeemEarly(50);

        assertEq(usdc.balanceOf(alice) - balBefore, 50 * ratePerBond);
        assertEq(bond.balanceOf(alice), 850);
    }

    function test_EarlyBuyback_RevertIfPoolExhausted() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        uint256 ratePerBond = 950e6;
        uint256 totalFunds  = 10 * ratePerBond; // only 10 bonds worth
        usdc.mint(issuer, totalFunds);
        vm.startPrank(issuer);
        usdc.approve(address(bond), totalFunds);
        bond.openEarlyBuyback(totalFunds, ratePerBond);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Bond: pool exhausted");
        bond.redeemEarly(11); // exceeds pool
    }

    function test_EarlyBuyback_RevertIfNotEnabled() public {
        // Create bond without buyback
        CorporateBond.BondTerms memory t = _makeBondTerms(CorporateBond.PaymentMode.COUPON);
        t.earlyBuybackEnabled = false;

        bytes memory initData = abi.encodeCall(
            CorporateBond.initialize,
            ("No Buyback Bond", "NBB", t, SETUP_FEE_BPS, COUPON_FEE_BPS,
             address(compliance), address(feeCollector), admin)
        );
        CorporateBond noBuyback = CorporateBond(address(new ERC1967Proxy(address(impl), initData)));
        vm.startPrank(admin);
        compliance.whitelist(address(noBuyback));
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), address(noBuyback));
        vm.stopPrank();

        _subscribe(noBuyback, alice, 900);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        noBuyback.activateBond();

        vm.startPrank(issuer);
        vm.expectRevert("Bond: buyback not enabled");
        noBuyback.openEarlyBuyback(1000e6, 950e6);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  10. COMPLIANCE / SECURITY TOKEN
    // ─────────────────────────────────────────────────────────────────────────

    function test_Transfer_RevertIfRecipientNotCompliant() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        vm.prank(alice);
        vm.expectRevert("Bond: recipient not compliant");
        bond.transfer(charlie, 10);
    }

    function test_Transfer_RevertIfSenderBlacklisted() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        vm.prank(admin);
        compliance.blacklist(alice, "AML flag");

        vm.prank(alice);
        vm.expectRevert("Bond: sender not compliant");
        bond.transfer(bob, 10);
    }

    function test_Transfer_Success_BothCompliant() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        vm.prank(alice);
        bond.transfer(bob, 50);
        assertEq(bond.balanceOf(bob), 50);
        assertEq(bond.balanceOf(alice), 850);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  11. PAUSE
    // ─────────────────────────────────────────────────────────────────────────

    function test_Pause_BlocksSubscription() public {
        vm.prank(admin);
        bond.pause();

        uint256 cost = FACE_VALUE;
        usdc.mint(alice, cost);
        vm.startPrank(alice);
        usdc.approve(address(bond), cost);
        vm.expectRevert();
        bond.subscribe(1);
        vm.stopPrank();
    }

    function test_Unpause_RestoresSubscription() public {
        vm.prank(admin);
        bond.pause();
        vm.prank(admin);
        bond.unpause();

        _subscribe(bond, alice, 1);
        assertEq(bond.subscriptions(alice), 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  12. VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function test_Decimals_IsZero() public view {
        assertEq(bond.decimals(), 0);
    }

    function test_ExpectedCouponAmount() public {
        _subscribe(bond, alice, 900);
        _activate(bond);
        vm.prank(alice);
        bond.claimAllocation();

        uint256 expected = bond.expectedCouponAmount();
        // 900 bonds × 1000e6 × 800 BPS × 90 days / (10000 × 365 days)
        uint256 manual = (900 * FACE_VALUE * COUPON_RATE_BPS * COUPON_FREQ)
            / (10_000 * 365 days);
        assertEq(expected, manual);
    }

    function test_GetTerms() public view {
        CorporateBond.BondTerms memory t = bond.getTerms();
        assertEq(t.faceValue,     FACE_VALUE);
        assertEq(t.totalIssuance, TOTAL_ISSUANCE);
        assertEq(t.softCap,       SOFT_CAP);
        assertEq(t.issuer,        issuer);
    }
}
