// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BondVault} from "../src/BondVault.sol";
import {BondaryWhitelist} from "../src/BondaryWhitelist.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Mock USDC (6 décimales)
// ─────────────────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Base fixture
// ─────────────────────────────────────────────────────────────────────────────

contract BondVaultTest is Test {
    address internal admin    = makeAddr("admin");
    address internal borrower = makeAddr("borrower");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal charlie  = makeAddr("charlie");  // non-KYC
    address internal anyone   = makeAddr("anyone");   // random, non-KYC, non-admin

    MockUSDC            internal usdc;
    BondaryWhitelist    internal wl;
    BondaryFeeCollector internal fc;
    BondVault           internal vault;

    uint256 internal constant RATE_BPS         = 800;
    uint256 internal constant PLATFORM_FEE_BPS = 1_000;
    uint256 internal constant SETUP_FEE_BPS    = 100;
    uint256 internal constant SOFT_CAP         = 100_000e6;
    uint256 internal constant HARD_CAP         = 500_000e6;
    uint256 internal constant MIN_DEPOSIT      = 50e6;
    uint256 internal constant LOAN_DURATION    = 365 days;
    uint256 internal constant GRACE_PERIOD     = 30 days;

    uint256 internal subscriptionEnd;

    function setUp() public virtual {
        usdc = new MockUSDC();
        wl   = new BondaryWhitelist(admin);
        fc   = new BondaryFeeCollector(admin);

        subscriptionEnd = block.timestamp + 30 days;

        BondVault.VaultParams memory params = _defaultParams();
        address impl = address(new BondVault());
        bytes memory init = abi.encodeCall(
            BondVault.initialize,
            (usdc, "Bondary Bond 2027", "BND27", params, admin)
        );
        vault = BondVault(address(new ERC1967Proxy(impl, init)));

        // Grant AUTHORIZED_SOURCE_ROLE to vault so notifyFeeReceived doesn't revert
        vm.prank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), address(vault));

        vm.startPrank(admin);
        wl.whitelist(alice);
        wl.whitelist(bob);
        vm.stopPrank();

        usdc.mint(alice,    200_000e6);
        usdc.mint(bob,      200_000e6);
        usdc.mint(borrower, 1_000_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _defaultParams() internal view returns (BondVault.VaultParams memory) {
        return BondVault.VaultParams({
            interestRateBps:        RATE_BPS,
            platformInterestFeeBps: PLATFORM_FEE_BPS,
            setupFeeBps:            SETUP_FEE_BPS,
            softCap:                SOFT_CAP,
            hardCap:                HARD_CAP,
            minDeposit:             MIN_DEPOSIT,
            subscriptionEnd:        subscriptionEnd,
            loanDuration:           LOAN_DURATION,
            gracePeriod:            GRACE_PERIOD,
            borrower:               borrower,
            whitelistAddr:          address(wl),
            feeCollectorAddr:       address(fc)
        });
    }

    function _deployVaultWith(BondVault.VaultParams memory params)
        internal returns (BondVault v)
    {
        address impl = address(new BondVault());
        bytes memory init = abi.encodeCall(
            BondVault.initialize,
            (usdc, "Test", "TST", params, admin)
        );
        v = BondVault(address(new ERC1967Proxy(impl, init)));
    }

    function _deposit(address investor, uint256 amount) internal {
        vm.startPrank(investor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, investor);
        vm.stopPrank();
    }

    function _activateLoan() internal {
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vault.activateLoan();
    }

    function _drawAll() internal {
        uint256 available = usdc.balanceOf(address(vault));
        vm.prank(borrower);
        vault.drawLoan(available);
    }

    function _repay() internal {
        uint256 debt = vault.currentDebt();
        vm.startPrank(borrower);
        usdc.approve(address(vault), debt + 1e6);
        vault.repayLoan();
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [1] Subscription
// ─────────────────────────────────────────────────────────────────────────────

contract SubscriptionTest is BondVaultTest {
    function test_InitialState() public view {
        assertEq(uint8(vault.state()), uint8(BondVault.State.SUBSCRIPTION));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_DepositMintsParts() public {
        _deposit(alice, 10_000e6);
        assertEq(vault.totalAssets(), 10_000e6);
        assertEq(vault.balanceOf(alice), 10_000e6);
    }

    function test_MultipleDeposits() public {
        _deposit(alice, 50_000e6);
        _deposit(bob,   50_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_RevertIfBelowMinDeposit() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 49e6);
        vm.expectRevert("BondVault: below min deposit");
        vault.deposit(49e6, alice);
        vm.stopPrank();
    }

    function test_RevertIfNotKYC() public {
        usdc.mint(charlie, 100_000e6);
        vm.startPrank(charlie);
        usdc.approve(address(vault), 100_000e6);
        vm.expectRevert("BondVault: not KYC");
        vault.deposit(100_000e6, charlie);
        vm.stopPrank();
    }

    function test_RevertIfHardCapExceeded() public {
        _deposit(alice, 200_000e6);
        _deposit(bob,   200_000e6);
        usdc.mint(alice, 200_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 200_000e6);
        vm.expectRevert("BondVault: hard cap exceeded");
        vault.deposit(200_000e6, alice);
        vm.stopPrank();
    }

    function test_RevertIfSubscriptionEnded() public {
        vm.warp(subscriptionEnd + 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert("BondVault: subscription ended");
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    function test_MaxDepositRespectsHardCap() public {
        _deposit(alice, 200_000e6);
        assertEq(vault.maxDeposit(alice), HARD_CAP - 200_000e6);
    }

    function test_MaxDepositZeroForNonKYC() public view {
        assertEq(vault.maxDeposit(charlie), 0);
    }

    function test_MaxDepositZeroAfterEnd() public {
        vm.warp(subscriptionEnd + 1);
        assertEq(vault.maxDeposit(alice), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [2] Initialize — validation des paramètres (audit fix)
// ─────────────────────────────────────────────────────────────────────────────

contract InitValidationTest is BondVaultTest {
    // CP-INIT-01  setupFeeBps >= 100% doit revert
    function test_RevertSetupFeeAt100Percent() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.setupFeeBps = 10_000;
        vm.expectRevert("BondVault: setup fee >= 100%");
        _deployVaultWith(p);
    }

    // CP-INIT-02  setupFeeBps = 9999 (99.99 %) doit passer
    function test_SetupFeeAt9999bpsIsValid() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.setupFeeBps = 9_999;
        BondVault v = _deployVaultWith(p);
        assertEq(v.setupFeeBps(), 9_999);
    }

    // CP-INIT-03  minDeposit = 0 doit revert
    function test_RevertZeroMinDeposit() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.minDeposit = 0;
        vm.expectRevert("BondVault: zero minDeposit");
        _deployVaultWith(p);
    }

    // CP-INIT-04  whitelistAddr = address(0) doit revert
    function test_RevertZeroWhitelistAddr() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.whitelistAddr = address(0);
        vm.expectRevert("BondVault: zero whitelist");
        _deployVaultWith(p);
    }

    // CP-INIT-05  feeCollectorAddr = address(0) doit revert
    function test_RevertZeroFeeCollectorAddr() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.feeCollectorAddr = address(0);
        vm.expectRevert("BondVault: zero feeCollector");
        _deployVaultWith(p);
    }

    // CP-INIT-06  platformInterestFeeBps = 10000 doit revert
    function test_RevertPlatformFeeAt100Percent() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.platformInterestFeeBps = 10_000;
        vm.expectRevert("BondVault: platform fee >= 100%");
        _deployVaultWith(p);
    }

    // CP-INIT-07  softCap > hardCap doit revert
    function test_RevertSoftCapAboveHardCap() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.softCap = HARD_CAP + 1;
        vm.expectRevert("BondVault: softCap > hardCap");
        _deployVaultWith(p);
    }

    // CP-INIT-08  subscriptionEnd dans le passé doit revert
    function test_RevertSubscriptionEndInPast() public {
        BondVault.VaultParams memory p = _defaultParams();
        p.subscriptionEnd = block.timestamp - 1;
        vm.expectRevert("BondVault: subscriptionEnd in past");
        _deployVaultWith(p);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [3] Donation resistance — _totalDeposited (audit fix)
// ─────────────────────────────────────────────────────────────────────────────

contract DonationResistanceTest is BondVaultTest {
    // CP-DON-01  totalDeposited() reflète exactement les dépôts (pas les donations)
    function test_TotalDepositedTracksOnlyDeposits() public {
        _deposit(alice, 100_000e6);
        assertEq(vault.totalDeposited(), 100_000e6);

        // Donation directe (bypass deposit())
        usdc.mint(address(vault), 50_000e6);

        // totalDeposited inchangé
        assertEq(vault.totalDeposited(), 100_000e6);
        // balanceOf reflète la donation, totalAssets aussi
        assertGt(usdc.balanceOf(address(vault)), vault.totalDeposited());
    }

    // CP-DON-02  Une donation ne permet pas de dépasser le hardCap
    //            (le check utilise _totalDeposited, pas balanceOf)
    function test_DonationDoesNotBlockDepositsUnderHardCap() public {
        // Donation qui pousse balanceOf à hardCap
        usdc.mint(address(vault), HARD_CAP);

        // Mais _totalDeposited = 0, donc alice peut encore déposer
        _deposit(alice, 100_000e6);
        assertEq(vault.totalDeposited(), 100_000e6);
    }

    // CP-DON-03  Une donation ne déclenche pas activateLoan() prématurément
    function test_DonationCannotForceEarlyActivation() public {
        // Donation jusqu'au hardCap dans balanceOf
        usdc.mint(address(vault), HARD_CAP);

        // _totalDeposited = 0 < softCap → activateLoan doit revert
        vm.prank(admin);
        vm.expectRevert("BondVault: soft cap not reached");
        vault.activateLoan();
    }

    // CP-DON-04  La donation ne triche pas la condition subscriptionEnd
    function test_DonationToHardCapDoesNotOpenActivationBeforeEnd() public {
        _deposit(alice, 200_000e6);
        // Donation pour compléter le hardCap sans passer subscriptionEnd
        usdc.mint(address(vault), HARD_CAP - 200_000e6);

        // _totalDeposited = 200k < hardCap → condition "hardCap reached" fausse
        vm.prank(admin);
        vm.expectRevert("BondVault: subscription still open");
        vault.activateLoan();
    }

    // CP-DON-05  hardCap atteint organiquement (via dépôts) ouvre activateLoan
    function test_OrganicHardCapOpensEarlyActivation() public {
        usdc.mint(alice, HARD_CAP);
        vm.startPrank(alice);
        usdc.approve(address(vault), HARD_CAP);
        vault.deposit(HARD_CAP, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.activateLoan();
        assertEq(uint8(vault.state()), uint8(BondVault.State.ACTIVE));
    }

    // CP-DON-06  failSubscription utilise _totalDeposited, pas balanceOf
    function test_DonationDoesNotPreventFailSubscription() public {
        _deposit(alice, 50_000e6); // sous softCap
        // Donation qui gonfle balanceOf au-delà du softCap
        usdc.mint(address(vault), SOFT_CAP + 1);

        vm.warp(subscriptionEnd + 1);
        // _totalDeposited = 50k < softCap → failSubscription doit réussir
        vm.prank(admin);
        vault.failSubscription();
        assertEq(uint8(vault.state()), uint8(BondVault.State.FAILED));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [4] emergencyFailSubscription — sortie permissionless (audit fix)
// ─────────────────────────────────────────────────────────────────────────────

contract EmergencyEscapeTest is BondVaultTest {
    uint256 internal constant ESCAPE_DELAY = 7 days;

    // CP-ESC-01  Réussit après subscriptionEnd + 7 jours si softCap non atteint
    function test_EmergencyFailSucceedsAfterDelay() public {
        _deposit(alice, 50_000e6); // sous softCap
        vm.warp(subscriptionEnd + ESCAPE_DELAY + 1);

        vm.prank(anyone);
        vault.emergencyFailSubscription();

        assertEq(uint8(vault.state()), uint8(BondVault.State.FAILED));
    }

    // CP-ESC-02  N'importe qui peut appeler (pas seulement l'admin)
    function test_AnyoneCanCallEmergencyFail() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + ESCAPE_DELAY + 1);

        // `anyone` n'a aucun rôle
        vm.prank(anyone);
        vault.emergencyFailSubscription();
        assertEq(uint8(vault.state()), uint8(BondVault.State.FAILED));
    }

    // CP-ESC-03  Revert avant subscriptionEnd
    function test_RevertEmergencyBeforeSubscriptionEnd() public {
        _deposit(alice, 50_000e6);
        vm.prank(anyone);
        vm.expectRevert("BondVault: escape delay not elapsed");
        vault.emergencyFailSubscription();
    }

    // CP-ESC-04  Revert entre subscriptionEnd et subscriptionEnd + 7j
    function test_RevertEmergencyInGracePeriod() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + ESCAPE_DELAY - 1);
        vm.prank(anyone);
        vm.expectRevert("BondVault: escape delay not elapsed");
        vault.emergencyFailSubscription();
    }

    // CP-ESC-05  Revert si softCap atteint (vault viable)
    function test_RevertEmergencyIfSoftCapMet() public {
        _deposit(alice, 100_000e6); // = softCap
        vm.warp(subscriptionEnd + ESCAPE_DELAY + 1);
        vm.prank(anyone);
        vm.expectRevert("BondVault: soft cap reached");
        vault.emergencyFailSubscription();
    }

    // CP-ESC-06  Les investisseurs récupèrent leurs fonds après emergencyFail
    function test_InvestorsRedeemAfterEmergencyFail() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + ESCAPE_DELAY + 1);
        vault.emergencyFailSubscription();

        uint256 shares = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, 50_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [5] UUPS upgrade timelock (audit fix)
// ─────────────────────────────────────────────────────────────────────────────

contract UpgradeTimelockTest is BondVaultTest {
    address internal newImpl;

    function setUp() public override {
        super.setUp();
        newImpl = address(new BondVault());
    }

    // CP-UPG-01  proposeUpgrade() émet UpgradeProposed et initialise l'état
    function test_ProposeUpgradeEmitsEvent() public {
        uint256 expectedTs = block.timestamp + 48 hours;
        vm.expectEmit(true, false, false, true, address(vault));
        emit BondVault.UpgradeProposed(newImpl, expectedTs);

        vm.prank(admin);
        vault.proposeUpgrade(newImpl);

        assertEq(vault.pendingUpgradeImpl(), newImpl);
        assertEq(vault.pendingUpgradeTimestamp(), expectedTs);
    }

    // CP-UPG-02  cancelUpgrade() réinitialise l'état pending
    function test_CancelUpgradeClearsPendingState() public {
        vm.prank(admin);
        vault.proposeUpgrade(newImpl);

        vm.prank(admin);
        vault.cancelUpgrade();

        assertEq(vault.pendingUpgradeImpl(), address(0));
        assertEq(vault.pendingUpgradeTimestamp(), 0);
    }

    // CP-UPG-03  upgradeToAndCall revert si aucune proposition
    function test_RevertUpgradeIfNothingProposed() public {
        vm.prank(admin);
        vm.expectRevert("BondVault: upgrade not proposed");
        vault.upgradeToAndCall(newImpl, "");
    }

    // CP-UPG-04  upgradeToAndCall revert si implémentation != celle proposée
    function test_RevertUpgradeIfImplMismatch() public {
        vm.prank(admin);
        vault.proposeUpgrade(newImpl);

        address otherImpl = address(new BondVault());
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(admin);
        vm.expectRevert("BondVault: upgrade not proposed");
        vault.upgradeToAndCall(otherImpl, "");
    }

    // CP-UPG-05  upgradeToAndCall revert si délai non écoulé
    function test_RevertUpgradeBeforeTimelock() public {
        vm.prank(admin);
        vault.proposeUpgrade(newImpl);

        // 47h59 : encore trop tôt
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(admin);
        vm.expectRevert("BondVault: timelock not elapsed");
        vault.upgradeToAndCall(newImpl, "");
    }

    // CP-UPG-06  upgradeToAndCall réussit exactement après 48h
    function test_UpgradeSucceedsAfterTimelock() public {
        vm.prank(admin);
        vault.proposeUpgrade(newImpl);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        vault.upgradeToAndCall(newImpl, "");

        // Après upgrade, l'état pending est nettoyé
        assertEq(vault.pendingUpgradeImpl(), address(0));
    }

    // CP-UPG-07  Non-admin ne peut pas proposer un upgrade
    function test_RevertProposeUpgradeByNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert();
        vault.proposeUpgrade(newImpl);
    }

    // CP-UPG-08  proposeUpgrade(address(0)) revert
    function test_RevertProposeZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("BondVault: zero impl");
        vault.proposeUpgrade(address(0));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [6] resolveDefault — événement zero-recovery (audit fix)
// ─────────────────────────────────────────────────────────────────────────────

contract ZeroRecoveryEventTest is BondVaultTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 200_000e6);
        _activateLoan();
        _drawAll();
        vm.warp(block.timestamp + LOAN_DURATION + GRACE_PERIOD + 1);
        vm.prank(admin);
        vault.declareDefault();
    }

    // CP-ZERO-01  resolveDefault(0) émet DefaultResolvedZeroRecovery
    function test_ZeroRecoveryEmitsEvent() public {
        vm.expectEmit(false, false, false, false, address(vault));
        emit BondVault.DefaultResolvedZeroRecovery();

        vm.prank(admin);
        vault.resolveDefault(0);
    }

    // CP-ZERO-02  resolveDefault avec montant > 0 n'émet PAS DefaultResolvedZeroRecovery
    function test_NonZeroRecoveryDoesNotEmitZeroEvent() public {
        uint256 amount = 50_000e6;
        usdc.mint(admin, amount);
        vm.startPrank(admin);
        usdc.approve(address(vault), amount);

        // On ne doit PAS voir cet event
        vm.recordLogs();
        vault.resolveDefault(amount);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 zeroSig = keccak256("DefaultResolvedZeroRecovery()");
        for (uint i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != zeroSig, "ZeroRecovery event must not be emitted");
        }
    }

    // CP-ZERO-03  resolveDefault(0) → vault CLOSED, investisseurs reçoivent 0
    function test_InvestorsReceiveZeroAfterZeroRecovery() public {
        vm.prank(admin);
        vault.resolveDefault(0);

        assertEq(uint8(vault.state()), uint8(BondVault.State.CLOSED));

        uint256 shares = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), before); // 0 reçu
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [7] Activation du prêt
// ─────────────────────────────────────────────────────────────────────────────

contract ActivationTest is BondVaultTest {
    function test_ActivateLoan() public {
        _deposit(alice, 200_000e6);
        _activateLoan();
        assertEq(uint8(vault.state()), uint8(BondVault.State.ACTIVE));
    }

    function test_SetupFeeCollected() public {
        _deposit(alice, 200_000e6);
        uint256 fcBefore = usdc.balanceOf(address(fc));
        _activateLoan();
        uint256 expectedFee = (200_000e6 * SETUP_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(address(fc)) - fcBefore, expectedFee);
    }

    function test_RevertActivateIfSoftCapNotMet() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vm.expectRevert("BondVault: soft cap not reached");
        vault.activateLoan();
    }

    function test_ActivateEarlyIfHardCapReached() public {
        usdc.mint(alice, HARD_CAP);
        vm.startPrank(alice);
        usdc.approve(address(vault), HARD_CAP);
        vault.deposit(HARD_CAP, alice);
        vm.stopPrank();
        vm.prank(admin);
        vault.activateLoan();
        assertEq(uint8(vault.state()), uint8(BondVault.State.ACTIVE));
    }

    function test_FailSubscription() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vault.failSubscription();
        assertEq(uint8(vault.state()), uint8(BondVault.State.FAILED));
    }

    function test_RefundAfterFailed() public {
        _deposit(alice, 50_000e6);
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vault.failSubscription();

        uint256 shares = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, 50_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [8] Cycle de vie actif
// ─────────────────────────────────────────────────────────────────────────────

contract ActiveLoanTest is BondVaultTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 200_000e6);
        _deposit(bob,   100_000e6);
        _activateLoan();
    }

    function test_DrawLoan() public {
        uint256 available = usdc.balanceOf(address(vault));
        vm.prank(borrower);
        vault.drawLoan(available);
        assertEq(vault.totalBorrowed(), available);
    }

    function test_TotalAssetsGrowsWithInterest() public {
        _drawAll();
        uint256 t0 = vault.totalAssets();
        vm.warp(block.timestamp + 180 days);
        assertGt(vault.totalAssets(), t0);
    }

    function test_SharePriceGrowsOverTime() public {
        _drawAll();
        uint256 price0 = vault.convertToAssets(1e6);
        vm.warp(block.timestamp + 365 days);
        assertGt(vault.convertToAssets(1e6), price0);
    }

    function test_PartialDraw() public {
        vm.prank(borrower);
        vault.drawLoan(100_000e6);
        vm.warp(block.timestamp + 180 days);
        vm.prank(borrower);
        vault.drawLoan(50_000e6);
        assertEq(vault.totalBorrowed(), 150_000e6);
    }

    function test_RevertDrawIfNotBorrower() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.drawLoan(10_000e6);
    }

    function test_FullRepayment() public {
        _drawAll();
        vm.warp(block.timestamp + 365 days);
        _repay();
        assertEq(uint8(vault.state()), uint8(BondVault.State.CLOSED));
    }

    function test_InterestFeeGoesToCollector() public {
        _drawAll();
        vm.warp(block.timestamp + 365 days);
        uint256 fcBefore = usdc.balanceOf(address(fc));
        _repay();
        assertGt(usdc.balanceOf(address(fc)), fcBefore);
    }

    function test_InvestorsRedeemAfterClose() public {
        _drawAll();
        vm.warp(block.timestamp + 365 days);
        _repay();
        uint256 shares = vault.balanceOf(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertGt(usdc.balanceOf(alice) - before, 200_000e6);
    }

    function test_RevertWithdrawWhileActive() public {
        _drawAll();
        vm.prank(alice);
        vm.expectRevert("BondVault: not redeemable");
        vault.withdraw(1e6, alice, alice);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [9] Défaut
// ─────────────────────────────────────────────────────────────────────────────

contract DefaultTest is BondVaultTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 200_000e6);
        _activateLoan();
        _drawAll();
    }

    function test_DeclareDefault() public {
        vm.warp(block.timestamp + LOAN_DURATION + GRACE_PERIOD + 1);
        vm.prank(admin);
        vault.declareDefault();
        assertEq(uint8(vault.state()), uint8(BondVault.State.DEFAULTED));
    }

    function test_RevertDefaultBeforeGracePeriod() public {
        vm.warp(block.timestamp + LOAN_DURATION);
        vm.prank(admin);
        vm.expectRevert("BondVault: grace period not elapsed");
        vault.declareDefault();
    }

    function test_ResolveDefaultWithPartialRecovery() public {
        vm.warp(block.timestamp + LOAN_DURATION + GRACE_PERIOD + 1);
        vm.prank(admin);
        vault.declareDefault();

        uint256 recovered = 100_000e6;
        vm.startPrank(admin);
        usdc.mint(admin, recovered);
        usdc.approve(address(vault), recovered);
        vault.resolveDefault(recovered);
        vm.stopPrank();

        assertEq(uint8(vault.state()), uint8(BondVault.State.CLOSED));
        assertEq(usdc.balanceOf(address(vault)), recovered);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [10] Security token
// ─────────────────────────────────────────────────────────────────────────────

contract SecurityTokenTest is BondVaultTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 50_000e6);
    }

    function test_TransferBetweenKYCAddresses() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, shares);
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_RevertTransferToNonKYC() public {
        vm.prank(alice);
        vm.expectRevert("BondVault: recipient not KYC");
        vault.transfer(charlie, 100e6);
    }

    function test_RevertTransferFromToNonKYC() public {
        vm.prank(alice);
        vault.approve(bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert("BondVault: recipient not KYC");
        vault.transferFrom(alice, charlie, 1_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [11] Pause
// ─────────────────────────────────────────────────────────────────────────────

contract PauseTest is BondVaultTest {
    function test_AdminCanPause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_DepositBlockedWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert();
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    function test_NonAdminCannotPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }
}
