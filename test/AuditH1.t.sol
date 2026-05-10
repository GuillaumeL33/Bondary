// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CorporateBond} from "../src/CorporateBond.sol";
import {BondFactory} from "../src/BondFactory.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {IIdentity} from "../src/interfaces/IERC3643.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10_000_000_000 * 1e6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stub ONCHAINID with a single management key (purpose 1) for `owner`.
contract IdentityStub is IIdentity {
    address public owner;
    constructor(address _owner) { owner = _owner; }
    function keyHasPurpose(bytes32 key, uint256 purpose) external view returns (bool) {
        return purpose == 1 && key == keccak256(abi.encode(owner));
    }
}

/// @dev Stub that deliberately doesn't implement keyHasPurpose for negative tests.
contract BadIdentity {
    function ping() external pure returns (uint256) { return 1; }
}

/**
 * @title AuditH1
 * @notice Tests for the H1 audit fixes (S-01 .. S-06).
 */
contract AuditH1Test is Test {
    BondFactory factory;
    CorporateBond impl;
    ComplianceManager compliance;
    BondaryFeeCollector feeCollector;
    MockToken usdc;

    address admin   = makeAddr("admin");
    address issuer  = makeAddr("issuer");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");

    uint256 constant FACE_VALUE       = 1e6;        // 1 USDC
    uint256 constant TOTAL_ISSUANCE   = 100_000;    // 100k bonds
    uint256 constant SOFT_CAP         = 10_000;
    uint256 constant ISSUANCE_PRICE   = 1e6;
    uint256 constant MIN_INVESTMENT   = 100e6;      // 100 USDC
    uint256 constant COUPON_RATE_BPS  = 500;        // 5%
    uint256 constant COUPON_FREQUENCY = 90 days;

    function setUp() public {
        vm.startPrank(admin);
        usdc         = new MockToken();
        compliance   = new ComplianceManager(admin);
        feeCollector = new BondaryFeeCollector(admin);
        impl         = new CorporateBond();
        factory      = new BondFactory(admin, address(impl), address(compliance), address(feeCollector));

        // Roles plumbing (cf Deploy.s.sol)
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), address(factory));
        compliance.grantRole(compliance.COMPLIANCE_ADMIN_ROLE(), address(factory));

        // Whitelist actors
        compliance.whitelist(issuer);
        compliance.whitelist(alice);
        compliance.whitelist(bob);
        compliance.whitelist(admin);

        vm.stopPrank();
    }

    function _newBond(CorporateBond.PaymentMode mode) internal returns (CorporateBond) {
        CorporateBond.BondTerms memory t = CorporateBond.BondTerms({
            faceValue:           FACE_VALUE,
            totalIssuance:       TOTAL_ISSUANCE,
            softCap:             SOFT_CAP,
            issuancePrice:       ISSUANCE_PRICE,
            minInvestment:       MIN_INVESTMENT,
            couponRate:          COUPON_RATE_BPS,
            maturityDate:        block.timestamp + 365 days,
            couponFrequency:     COUPON_FREQUENCY,
            paymentMode:         mode,
            earlyBuybackEnabled: false,
            subscriptionEnd:     block.timestamp + 30 days,
            paymentToken:        address(usdc),
            issuer:              issuer
        });
        vm.prank(admin);
        address bond = factory.createBond("Test Bond", "TBND", t, 100, 50, admin);
        return CorporateBond(bond);
    }

    function _activate(CorporateBond bond) internal {
        usdc.mint(alice, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(bond), 50_000e6);
        bond.subscribe(50_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        vm.prank(admin);
        bond.activateBond();

        vm.prank(alice);
        bond.claimAllocation();
    }

    // ---- S-01 : repayPrincipal pays the stub coupon ------------------------

    function test_S01_StubCouponPaidOnRepayPrincipal() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        vm.warp(block.timestamp + COUPON_FREQUENCY);
        usdc.mint(issuer, 100_000e6);
        vm.startPrank(issuer);
        usdc.approve(address(bond), 100_000e6);
        bond.payCoupon();
        vm.stopPrank();

        uint256 alicePendingBefore = bond.pendingCoupons(alice);
        assertGt(alicePendingBefore, 0, "first coupon should accrue to alice");

        vm.warp(bond.terms().maturityDate + 1 days);
        vm.prank(admin);
        bond.signalMaturity();

        uint256 stubExpected = bond.expectedFinalCouponAmount();
        assertGt(stubExpected, 0, "stub should be > 0");

        vm.startPrank(issuer);
        usdc.approve(address(bond), 1_000_000e6);
        bond.repayPrincipal();
        vm.stopPrank();

        assertTrue(bond.finalCouponPaid(), "finalCouponPaid flag should be set");
        uint256 alicePendingAfter = bond.pendingCoupons(alice);
        assertGt(alicePendingAfter, alicePendingBefore, "stub coupon should accrue to alice");
    }

    function test_S01_RepayPrincipalIdempotent() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        vm.warp(bond.terms().maturityDate + 1 days);
        vm.prank(admin);
        bond.signalMaturity();

        usdc.mint(issuer, 1_000_000e6);
        vm.startPrank(issuer);
        usdc.approve(address(bond), 1_000_000e6);
        bond.repayPrincipal();
        vm.stopPrank();

        assertTrue(bond.finalCouponPaid());

        vm.expectRevert("Bond: already repaid");
        vm.prank(issuer);
        bond.repayPrincipal();
    }

    // ---- S-02 : agent mint cap ---------------------------------------------

    function test_S02_AgentMintCappedInActive() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        // Cap = 1% of 100,000 = 1,000 bonds per 24h.
        uint256 cap = bond.remainingAgentMintCap();
        assertEq(cap, 1_000, "cap should be 1% of totalIssuance");

        vm.prank(admin);
        bond.mint(bob, 1_000);

        vm.expectRevert("Bond: agent mint cap exceeded");
        vm.prank(admin);
        bond.mint(bob, 1);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(admin);
        bond.mint(bob, 1_000);
        assertEq(bond.balanceOf(bob), 2_000);
    }

    function test_S02_AgentMintNotCappedInSubscription() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);

        vm.prank(admin);
        bond.mint(bob, 50_000);
        assertEq(bond.balanceOf(bob), 50_000);
    }

    // ---- S-03 : emergency redemption rate timelock 7d ----------------------

    function test_S03_EmergencyRateRequiresGracePeriod() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        vm.warp(bond.terms().maturityDate + 1 days);
        vm.prank(admin);
        bond.signalMaturity();

        vm.expectRevert("Bond: grace period not expired");
        vm.prank(admin);
        bond.proposeEmergencyRedemptionRate(0.5e18);
    }

    function test_S03_EmergencyRateTimelockEnforced() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        vm.warp(bond.terms().maturityDate + 31 days);
        vm.prank(admin);
        bond.signalMaturity();

        vm.prank(admin);
        bond.proposeEmergencyRedemptionRate(0.5e18);

        vm.expectRevert("Bond: timelocked");
        vm.prank(admin);
        bond.executeEmergencyRedemptionRate();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(admin);
        bond.executeEmergencyRedemptionRate();
        assertEq(bond.redemptionRate(), 0.5e18);
    }

    function test_S03_EmergencyRateCancellable() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        _activate(bond);

        vm.warp(bond.terms().maturityDate + 31 days);
        vm.prank(admin);
        bond.signalMaturity();

        vm.prank(admin);
        bond.proposeEmergencyRedemptionRate(0.5e18);

        vm.prank(admin);
        bond.cancelEmergencyRedemptionRate();

        assertEq(bond.proposedEmergencyRedemptionRate(), 0);
    }

    // ---- S-04 : UPGRADE_DELAY = 7 days -------------------------------------

    function test_S04_UpgradeDelayIs7DaysOnBond() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        assertEq(bond.UPGRADE_DELAY(), 7 days);
    }

    function test_S04_UpgradeDelayIs7DaysOnFactory() public view {
        assertEq(factory.UPGRADE_DELAY(), 7 days);
    }

    // ---- S-05 : bindToken admin-only ---------------------------------------

    function test_S05_BindTokenRevertsForArbitraryCaller() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert();
        vm.prank(attacker);
        compliance.bindToken(makeAddr("fakeToken"));
    }

    function test_S05_FactoryCanBindNewBond() public {
        CorporateBond bond = _newBond(CorporateBond.PaymentMode.COUPON);
        assertTrue(compliance.isTokenBound(address(bond)));
    }

    // ---- S-06 : IIdentity validation ---------------------------------------

    function test_S06_RegisterIdentityRejectsBadIdentity() public {
        BadIdentity bad = new BadIdentity();
        vm.prank(admin);
        vm.expectRevert();
        compliance.registerIdentity(makeAddr("user"), IIdentity(address(bad)), 250);
    }

    function test_S06_RegisterIdentityAcceptsValidStub() public {
        address user = makeAddr("user");
        IdentityStub idStub = new IdentityStub(user);

        vm.prank(admin);
        compliance.registerIdentity(user, IIdentity(address(idStub)), 250);
        assertTrue(compliance.isVerified(user));
    }

    function test_S06_LegacyWhitelistStillWorks() public {
        address user = makeAddr("user");
        vm.prank(admin);
        compliance.whitelist(user);
        assertTrue(compliance.isVerified(user));
    }
}
