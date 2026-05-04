// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CorporateBond} from "../src/CorporateBond.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {BondFactory} from "../src/BondFactory.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";
import {IIdentity} from "../src/interfaces/IERC3643.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// Minimal ONCHAINID for ERC-3643 identity registration.
// keyHasPurpose is required only by recoveryAddress (not used in this sim).
contract OnchainID is IIdentity {
    mapping(bytes32 => mapping(uint256 => bool)) private _keys;

    function addKey(address wallet, uint256 purpose) external {
        _keys[keccak256(abi.encode(wallet))][purpose] = true;
    }

    function keyHasPurpose(bytes32 key, uint256 purpose) external view returns (bool) {
        return _keys[key][purpose];
    }
}

/**
 * @title LorealSimulationTest
 * @notice Full lifecycle simulation of a L'Oreal SA 4% 3-year bond, 1 000 000 EUR.
 *
 *  Bond structure:
 *    1 000 bonds × 1 000 EUR (EURC, 6 decimals) = 1 000 000 EUR notional
 *    4% annual coupon, quarterly (90 days), 3-year maturity
 *    1% setup fee, 0.5% platform coupon fee
 *
 *  Investors:
 *    Fond A (Paris / FR):  subscribes 400 bonds, claims immediately
 *    Fond B (London / GB): subscribes 350 bonds, claims immediately
 *    Fond C (Zurich / CH): subscribes 250 bonds, claims AFTER Q1 (retroactive demo)
 *    Fond D (Dubai / AE):  buys 100 bonds from Fond C on secondary market after Q1
 *
 *  Lifecycle:
 *    1. Subscription  (Fond A + B + C → hard cap 1 000 bonds hit)
 *    2. Activation    (L'Oreal receives 990 000 EUR net, 10 000 EUR setup fee)
 *    3. Q1 coupon paid by L'Oreal, Fond C has not yet claimed tokens
 *    4. Fond C claims allocation → retroactive Q1 coupon credited
 *    5. Fond C creates sell order (100 bonds @ 1 005 EUR), Fond D fills it
 *    6. Q2 – Q12 coupons (remaining 11 quarters)
 *    7. Maturity signaled, L'Oreal repays 1 000 000 EUR principal
 *    8. All investors redeem → bond CLOSED
 */
contract LorealSimulationTest is Test {
    // ─── Actors ───────────────────────────────────────────────────────────────
    address admin  = makeAddr("bondary_admin");
    address loreal = makeAddr("loreal_sa");
    address fondA  = makeAddr("fond_a_fr");   // France       — 400 bonds
    address fondB  = makeAddr("fond_b_gb");   // UK           — 350 bonds
    address fondC  = makeAddr("fond_c_ch");   // Switzerland  — 250 bonds (→ 150 after sale)
    address fondD  = makeAddr("fond_d_ae");   // UAE          — 100 bonds (secondary buyer)

    // ─── Contracts ────────────────────────────────────────────────────────────
    ERC20Mock           eurc;
    ComplianceManager   compliance;
    BondaryFeeCollector feeCollector;
    BondFactory         factory;
    BondaryMarketplace  marketplace;
    CorporateBond       bond;

    // ─── Bond Parameters ──────────────────────────────────────────────────────
    uint256 constant FACE      = 1_000e6;   // 1 000 EUR per bond (EURC, 6 decimals)
    uint256 constant ISSUANCE  = 1_000;     // 1 000 bonds = 1 000 000 EUR notional
    uint256 constant SOFT_CAP  = 900;
    uint256 constant RATE_BPS  = 400;       // 4 % annual
    uint256 constant FREQ      = 90 days;   // quarterly
    uint256 constant SETUP_BPS = 100;       // 1 %
    uint256 constant COUP_BPS  = 50;        // 0.5 %

    uint256 subEnd;
    uint256 maturity;

    // ─────────────────────────────────────────────────────────────────────────
    //  setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        subEnd   = block.timestamp + 14 days;
        maturity = subEnd + 3 * 365 days;

        eurc         = new ERC20Mock();
        compliance   = new ComplianceManager(admin);
        feeCollector = new BondaryFeeCollector(admin);

        CorporateBond impl = new CorporateBond();
        factory = new BondFactory(admin, address(impl), address(compliance), address(feeCollector));

        // 50 bps trading fee, 200 bps early-exit penalty
        marketplace = new BondaryMarketplace(
            admin, address(compliance), address(feeCollector), address(factory), 50, 200
        );

        // factory needs DEFAULT_ADMIN_ROLE on feeCollector to grant AUTHORIZED_SOURCE_ROLE to new bonds
        vm.startPrank(admin);
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(),        address(factory));
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(),    address(marketplace));
        vm.stopPrank();

        // ERC-3643 identity registration with country codes
        OnchainID idLoreal = new OnchainID();
        OnchainID idA      = new OnchainID();
        OnchainID idB      = new OnchainID();
        OnchainID idC      = new OnchainID();
        OnchainID idD      = new OnchainID();

        vm.startPrank(admin);
        compliance.registerIdentity(loreal, IIdentity(address(idLoreal)), 33);   // France
        compliance.registerIdentity(fondA,  IIdentity(address(idA)),      33);   // France
        compliance.registerIdentity(fondB,  IIdentity(address(idB)),      44);   // UK
        compliance.registerIdentity(fondC,  IIdentity(address(idC)),      41);   // Switzerland
        compliance.registerIdentity(fondD,  IIdentity(address(idD)),      971);  // UAE
        compliance.whitelist(address(marketplace)); // marketplace escrow must be verified
        vm.stopPrank();

        // Deploy the bond through the factory (auto-grants AUTHORIZED_SOURCE_ROLE)
        CorporateBond.BondTerms memory t = CorporateBond.BondTerms({
            faceValue:           FACE,
            totalIssuance:       ISSUANCE,
            softCap:             SOFT_CAP,
            issuancePrice:       FACE,
            minInvestment:       FACE,
            couponRate:          RATE_BPS,
            maturityDate:        maturity,
            couponFrequency:     FREQ,
            paymentMode:         CorporateBond.PaymentMode.COUPON,
            earlyBuybackEnabled: false,
            subscriptionEnd:     subEnd,
            paymentToken:        address(eurc),
            issuer:              loreal
        });

        vm.prank(admin);
        bond = CorporateBond(
            factory.createBond("L'Oreal SA 4pct 3Y", "LOR4Y3", t, SETUP_BPS, COUP_BPS, admin)
        );

        // Bond contract itself must be KYC-verified (mint bypasses address(0) check,
        // but compliance.canTransfer checks the recipient on mint paths)
        vm.prank(admin);
        compliance.whitelist(address(bond));

        // Fund wallets
        eurc.mint(fondA,  400 * FACE);
        eurc.mint(fondB,  350 * FACE);
        eurc.mint(fondC,  250 * FACE);
        eurc.mint(fondD,  200_000e6);      // budget for secondary purchase
        eurc.mint(loreal, 2_000_000e6);    // covers all coupons + principal
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Full lifecycle simulation
    // ─────────────────────────────────────────────────────────────────────────

    function test_LorealBond_FullLifecycle() public {
        console2.log("================================================================");
        console2.log("  L'Oreal SA 4pct 3Y Bond - Simulation (1 000 000 EUR notional)");
        console2.log("================================================================");

        // ─── 1. SUBSCRIPTION ─────────────────────────────────────────────────
        console2.log("\n--- 1. Subscription ---");

        vm.startPrank(fondA);
        eurc.approve(address(bond), 400 * FACE);
        bond.subscribe(400);
        vm.stopPrank();

        vm.startPrank(fondB);
        eurc.approve(address(bond), 350 * FACE);
        bond.subscribe(350);
        vm.stopPrank();

        vm.startPrank(fondC);
        eurc.approve(address(bond), 250 * FACE);
        bond.subscribe(250);
        vm.stopPrank();

        assertEq(bond.totalSubscribed(), 1_000, "hard cap not hit");
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.SUBSCRIPTION));

        console2.log("Fond A (FR)  : 400 bonds subscribed  (400 000 EUR)");
        console2.log("Fond B (GB)  : 350 bonds subscribed  (350 000 EUR)");
        console2.log("Fond C (CH)  : 250 bonds subscribed  (250 000 EUR)");
        console2.log("Total raised :", bond.totalPaymentReceived() / 1e6, "EUR - hard cap hit");

        // ─── 2. ACTIVATION ───────────────────────────────────────────────────
        console2.log("\n--- 2. Activation ---");

        vm.warp(subEnd + 1);

        uint256 fcBalBefore    = eurc.balanceOf(address(feeCollector));
        uint256 lorealBalBefore = eurc.balanceOf(loreal);

        vm.prank(admin);
        bond.activateBond();

        uint256 setupFee      = eurc.balanceOf(address(feeCollector)) - fcBalBefore;
        uint256 lorealReceived = eurc.balanceOf(loreal) - lorealBalBefore;

        assertEq(uint8(bond.state()), uint8(CorporateBond.State.ACTIVE));
        assertEq(bond.couponEligibleSupply(), 1_000);
        assertEq(lorealReceived, 990_000e6,  "issuer net proceeds");
        assertEq(setupFee,       10_000e6,   "setup fee 1%");

        console2.log("Setup fee (1%%):           ", setupFee       / 1e6, "EUR -> FeeCollector");
        console2.log("L'Oreal net proceeds:      ", lorealReceived / 1e6, "EUR");
        console2.log("Bond state: ACTIVE  |  couponEligibleSupply: 1 000");

        // ─── 3. ALLOCATIONS: A + B claim immediately, C delays ───────────────
        console2.log("\n--- 3. Allocation claims (C waits) ---");

        vm.prank(fondA); bond.claimAllocation();
        vm.prank(fondB); bond.claimAllocation();
        // fondC intentionally delays — will claim after Q1 to show retroactive coupon

        assertEq(bond.balanceOf(fondA), 400);
        assertEq(bond.balanceOf(fondB), 350);
        assertEq(bond.balanceOf(fondC), 0);

        console2.log("Fond A: 400 bond tokens received");
        console2.log("Fond B: 350 bond tokens received");
        console2.log("Fond C: waiting (retroactive coupon demo)");

        // ─── 4. Q1 COUPON ────────────────────────────────────────────────────
        console2.log("\n--- 4. Q1 Coupon (day 90) ---");

        vm.warp(bond.nextCouponDate());

        uint256 grossCoupon = bond.expectedCouponAmount();
        uint256 platFee1    = grossCoupon * COUP_BPS / 10_000;
        uint256 netCoupon   = grossCoupon - platFee1;

        vm.startPrank(loreal);
        eurc.approve(address(bond), grossCoupon);
        bond.payCoupon();
        vm.stopPrank();

        assertEq(bond.couponsPaid(), 1);

        // pendingCoupons view: fondA (400 bonds), fondB (350 bonds)
        uint256 pendingA = bond.pendingCoupons(fondA);
        uint256 pendingB = bond.pendingCoupons(fondB);

        console2.log("Gross coupon (L'Oreal pays):", grossCoupon / 1e6, "EUR");
        console2.log("Platform fee (0.5%%):        ", platFee1    / 1e6, "EUR");
        console2.log("Net distributed:             ", netCoupon   / 1e6, "EUR");
        console2.log("Fond A pending (400/1000):   ", pendingA    / 1e6, "EUR");
        console2.log("Fond B pending (350/1000):   ", pendingB    / 1e6, "EUR");
        console2.log("Fond C: 0 tokens held -> 0 pending (will get retroactive credit)");

        // Sanity: A+B should total 750/1000 of netCoupon
        assertEq(pendingA + pendingB, netCoupon * 750 / 1_000);

        // ─── 5. FOND C LATE CLAIM → RETROACTIVE Q1 COUPON ───────────────────
        console2.log("\n--- 5. Fond C late claim (after Q1) ---");

        vm.prank(fondC);
        bond.claimAllocation();

        assertEq(bond.balanceOf(fondC), 250);

        uint256 pendingC = bond.pendingCoupons(fondC);

        // claimAllocation() retroactively credits: 250 × totalCouponPerToken / PRECISION
        assertEq(pendingC, netCoupon * 250 / 1_000, "retroactive Q1 for C");

        console2.log("Fond C tokens received:       250");
        console2.log("Fond C retroactive Q1 coupon:", pendingC / 1e6, "EUR (250/1000 of net)");
        console2.log("Total coupon distributed:    ", (pendingA + pendingB + pendingC) / 1e6, "EUR");

        // Integer division in dividend-per-token loses ≤1 wei per investor
        assertApproxEqAbs(pendingA + pendingB + pendingC, netCoupon, 3, "total coupon within rounding");

        // ─── 6. SECONDARY MARKET: C SELLS 100 BONDS TO D ────────────────────
        console2.log("\n--- 6. Secondary market (post-Q1, pre-Q2) ---");

        uint256 price      = 1_005e6;           // 1 005 EUR/bond (5 EUR premium)
        uint256 sellAmount = 100;
        uint256 totalCost  = sellAmount * price;
        uint256 trFee      = totalCost * 50  / 10_000; // 0.5% trading
        uint256 penFee     = totalCost * 200 / 10_000; // 2.0% early exit (ACTIVE state)
        uint256 cGets      = totalCost - trFee - penFee;

        // Fond C creates sell order
        vm.startPrank(fondC);
        bond.approve(address(marketplace), sellAmount);
        uint256 orderId = marketplace.createSellOrder(address(bond), sellAmount, price);
        vm.stopPrank();

        assertEq(bond.balanceOf(fondC), 150, "100 bonds in escrow");

        // Fond D fills the order
        vm.startPrank(fondD);
        eurc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        assertEq(bond.balanceOf(fondD), 100);
        assertEq(bond.balanceOf(fondC), 150);

        console2.log("Price per bond (secondary):  ", price    / 1e6, "EUR (par + 5 EUR premium)");
        console2.log("Total cost for Fond D:        ", totalCost / 1e6, "EUR");
        console2.log("Trading fee (0.5%%):           ", trFee    / 1e6, "EUR -> FeeCollector");
        console2.log("Early exit penalty (2%%):      ", penFee   / 1e6, "EUR -> FeeCollector");
        console2.log("Fond C receives (net):        ", cGets    / 1e6, "EUR");
        console2.log("Fond D: 100 bond tokens received");

        // ─── 7. Q2 – Q12 COUPONS ─────────────────────────────────────────────
        console2.log("\n--- 7. Q2 through Q12 (11 quarterly coupons) ---");

        uint256 totalCouponsIssuer = grossCoupon; // Q1 already counted
        for (uint256 q = 2; q <= 12; q++) {
            vm.warp(bond.nextCouponDate());
            uint256 qGross = bond.expectedCouponAmount();
            vm.startPrank(loreal);
            eurc.approve(address(bond), qGross);
            bond.payCoupon();
            vm.stopPrank();
            totalCouponsIssuer += qGross;
        }

        assertEq(bond.couponsPaid(), 12);

        // couponEligibleSupply unchanged throughout (bonds only burned at redemption)
        assertEq(bond.couponEligibleSupply(), 1_000);

        console2.log("Quarterly coupon (constant): ", grossCoupon         / 1e6, "EUR x 12");
        console2.log("Total coupons by L'Oreal:    ", totalCouponsIssuer  / 1e6, "EUR");

        // ─── 8. MATURITY + PRINCIPAL REPAYMENT ───────────────────────────────
        console2.log("\n--- 8. Maturity & principal repayment ---");

        vm.warp(maturity + 1);
        bond.signalMaturity();
        assertEq(uint8(bond.state()), uint8(CorporateBond.State.MATURED));

        uint256 principal = bond.couponEligibleSupply() * FACE; // 1 000 × 1 000e6
        assertEq(principal, 1_000_000e6);

        vm.startPrank(loreal);
        eurc.approve(address(bond), principal);
        bond.repayPrincipal();
        vm.stopPrank();

        console2.log("Bond state: MATURED");
        console2.log("L'Oreal repays principal:    ", principal / 1e6, "EUR (1 000 bonds x 1 000 EUR)");

        // ─── 9. REDEMPTION (all investors) ───────────────────────────────────
        console2.log("\n--- 9. Redemption ---");

        uint256 bA_before = eurc.balanceOf(fondA);
        vm.prank(fondA); bond.redeemBonds(400);
        uint256 fondAReceived = eurc.balanceOf(fondA) - bA_before;

        uint256 bB_before = eurc.balanceOf(fondB);
        vm.prank(fondB); bond.redeemBonds(350);
        uint256 fondBReceived = eurc.balanceOf(fondB) - bB_before;

        uint256 bD_before = eurc.balanceOf(fondD);
        vm.prank(fondD); bond.redeemBonds(100);
        uint256 fondDReceived = eurc.balanceOf(fondD) - bD_before;

        // Fond C is last → triggers CLOSED
        uint256 bC_before = eurc.balanceOf(fondC);
        vm.prank(fondC); bond.redeemBonds(150);
        uint256 fondCReceived = eurc.balanceOf(fondC) - bC_before;

        assertEq(uint8(bond.state()), uint8(CorporateBond.State.CLOSED), "bond not closed");
        assertEq(bond.balanceOf(fondA), 0);
        assertEq(bond.balanceOf(fondB), 0);
        assertEq(bond.balanceOf(fondC), 0);
        assertEq(bond.balanceOf(fondD), 0);

        // Each investor must receive at least their principal back
        assertGt(fondAReceived, 400 * FACE, "A: below principal");
        assertGt(fondBReceived, 350 * FACE, "B: below principal");
        assertGt(fondCReceived, 150 * FACE, "C: below principal");
        assertGt(fondDReceived, 100 * FACE, "D: below principal");

        console2.log("Fond A (400 bonds): receives", fondAReceived / 1e6, "EUR  [principal + 12 coupons]");
        console2.log("Fond B (350 bonds): receives", fondBReceived / 1e6, "EUR  [principal + 12 coupons]");
        console2.log("Fond C (150 bonds): receives", fondCReceived / 1e6, "EUR  [principal + Q1-retro + Q2-Q12]");
        console2.log("Fond D (100 bonds): receives", fondDReceived / 1e6, "EUR  [principal + Q2-Q12 (11 qtrs)]");

        uint256 totalInvestorReceived = fondAReceived + fondBReceived + fondCReceived + fondDReceived;
        console2.log("\nTotal returned to investors:", totalInvestorReceived / 1e6, "EUR");
        console2.log("Bond state: CLOSED");

        // ─── 10. SUMMARY ─────────────────────────────────────────────────────
        console2.log("\n--- 10. Platform revenue summary ---");

        uint256 fcFinal = eurc.balanceOf(address(feeCollector));
        console2.log("FeeCollector balance (setup+coupons+marketplace):", fcFinal / 1e6, "EUR");

        console2.log("\n================================================================");
        console2.log("  Simulation complete - all assertions passed");
        console2.log("================================================================");
    }
}
