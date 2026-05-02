// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BondVault} from "../src/BondVault.sol";
import {BondaryWhitelist} from "../src/BondaryWhitelist.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Mock USDC (6 décimales, comme USDC/EURC réels)
// ─────────────────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Fixtures partagées
// ─────────────────────────────────────────────────────────────────────────────

contract BondVaultTest is Test {
    // Acteurs
    address internal admin    = makeAddr("admin");
    address internal borrower = makeAddr("borrower");
    address internal alice    = makeAddr("alice");    // investisseur
    address internal bob      = makeAddr("bob");      // investisseur
    address internal charlie  = makeAddr("charlie"); // non-KYC

    // Contrats
    MockUSDC          internal usdc;
    BondaryWhitelist  internal wl;
    BondaryFeeCollector internal fc;
    BondVault         internal vault;

    // Paramètres par défaut
    uint256 internal constant RATE_BPS         = 800;   // 8 %
    uint256 internal constant PLATFORM_FEE_BPS = 1_000; // 10 % des intérêts
    uint256 internal constant SETUP_FEE_BPS    = 100;   // 1 % du montant levé
    uint256 internal constant SOFT_CAP         = 100_000e6;  // 100 000 USDC
    uint256 internal constant HARD_CAP         = 500_000e6;  // 500 000 USDC
    uint256 internal constant MIN_DEPOSIT      = 50e6;       // 50 USDC
    uint256 internal constant LOAN_DURATION    = 365 days;
    uint256 internal constant GRACE_PERIOD     = 30 days;

    uint256 internal subscriptionEnd;

    function setUp() public virtual {
        usdc = new MockUSDC();
        wl   = new BondaryWhitelist(admin);
        fc   = new BondaryFeeCollector(admin);

        subscriptionEnd = block.timestamp + 30 days;

        BondVault.VaultParams memory params = BondVault.VaultParams({
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

        address impl  = address(new BondVault());
        bytes memory  init = abi.encodeCall(
            BondVault.initialize,
            (usdc, "Bondary Bond 2027", "BND27", params, admin)
        );
        vault = BondVault(address(new ERC1967Proxy(impl, init)));

        // KYC
        vm.startPrank(admin);
        wl.whitelist(alice);
        wl.whitelist(bob);
        vm.stopPrank();

        // Fonds
        usdc.mint(alice, 200_000e6);
        usdc.mint(bob,   200_000e6);
        usdc.mint(borrower, 1_000_000e6); // pour rembourser
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

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
        usdc.approve(address(vault), debt + 1e6); // +1 USDC de marge
        vault.repayLoan();
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Souscription
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
        assertEq(vault.balanceOf(alice), 10_000e6); // 1:1 au départ
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
        // Déjà 400k ; tenter 200k de plus (dépasse le hardCap de 500k)
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
        uint256 remaining = vault.maxDeposit(alice);
        assertEq(remaining, HARD_CAP - 200_000e6);
    }

    function test_MaxDepositZeroForNonKYC() public view {
        assertEq(vault.maxDeposit(charlie), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Activation du prêt
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
        _deposit(alice, 50_000e6); // 50k < softCap 100k
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vm.expectRevert("BondVault: soft cap not reached");
        vault.activateLoan();
    }

    function test_ActivateEarlyIfHardCapReached() public {
        _deposit(alice, 200_000e6);
        _deposit(bob,   200_000e6);
        // Hard cap atteint à 400k < 500k ? Non, on remplit jusqu'au hard cap
        usdc.mint(alice, 100_000e6);
        _deposit(alice, 100_000e6); // Total = 500k = hardCap
        // On peut activer avant la fin de souscription
        vm.prank(admin);
        vault.activateLoan();
        assertEq(uint8(vault.state()), uint8(BondVault.State.ACTIVE));
    }

    function test_FailSubscription() public {
        _deposit(alice, 50_000e6); // sous le softCap
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

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 balBefore   = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(usdc.balanceOf(alice) - balBefore, 50_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Cycle de vie actif (tirage + intérêts + remboursement)
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
        assertEq(usdc.balanceOf(borrower) - 1_000_000e6, available);
        assertEq(vault.totalBorrowed(), available);
    }

    function test_TotalAssetsGrowsWithInterest() public {
        _drawAll();
        uint256 t0 = vault.totalAssets();
        vm.warp(block.timestamp + 180 days);
        uint256 t1 = vault.totalAssets();
        assertGt(t1, t0, "totalAssets doit croitre avec les interets");
    }

    function test_SharePriceGrowsOverTime() public {
        _drawAll();
        uint256 price0 = vault.convertToAssets(1e6); // 1 part au départ
        vm.warp(block.timestamp + 365 days);
        uint256 price1 = vault.convertToAssets(1e6);
        assertGt(price1, price0, "le prix de part doit augmenter");
    }

    function test_PartialDraw() public {
        vm.prank(borrower);
        vault.drawLoan(100_000e6);
        assertEq(vault.totalBorrowed(), 100_000e6);

        vm.warp(block.timestamp + 180 days);

        vm.prank(borrower);
        vault.drawLoan(50_000e6); // 2ème tirage
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
        assertEq(vault.totalBorrowed(), 0);
    }

    function test_InterestFeeGoesToCollector() public {
        _drawAll();
        vm.warp(block.timestamp + 365 days);

        uint256 fcBefore = usdc.balanceOf(address(fc));
        _repay();
        uint256 fcAfter = usdc.balanceOf(address(fc));

        // Le FeeCollector doit avoir reçu des frais (en plus des setup fees)
        // Les frais d'intérêts s'accumulent depuis l'activation
        assertGt(fcAfter, fcBefore, "FeeCollector doit recevoir les frais d interets");
    }

    function test_InvestorsRedeemAfterClose() public {
        _drawAll();
        vm.warp(block.timestamp + 365 days);
        _repay();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;

        // Alice a 200k sur 300k total → elle reçoit 2/3 des actifs
        assertGt(aliceReceived, 200_000e6, "Alice doit recevoir plus que son depot initial");
    }

    function test_RevertWithdrawWhileActive() public {
        _drawAll();
        vm.prank(alice);
        vm.expectRevert("BondVault: not redeemable");
        vault.withdraw(1e6, alice, alice);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Défaut
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

        // Admin récupère 100k via procédure légale et injecte dans le vault
        uint256 recovered = 100_000e6;
        vm.startPrank(admin);
        usdc.mint(admin, recovered);
        usdc.approve(address(vault), recovered);
        vault.resolveDefault(recovered);
        vm.stopPrank();

        assertEq(uint8(vault.state()), uint8(BondVault.State.CLOSED));
        assertEq(usdc.balanceOf(address(vault)), recovered);
    }

    function test_ResolveDefaultWithZeroRecovery() public {
        vm.warp(block.timestamp + LOAN_DURATION + GRACE_PERIOD + 1);
        vm.prank(admin);
        vault.declareDefault();

        vm.prank(admin);
        vault.resolveDefault(0);

        assertEq(uint8(vault.state()), uint8(BondVault.State.CLOSED));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Security token (transferts restreints)
// ─────────────────────────────────────────────────────────────────────────────

contract SecurityTokenTest is BondVaultTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 50_000e6);
    }

    function test_TransferBetweenKYCAddresses() public {
        vm.prank(admin);
        wl.whitelist(bob);

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

    function test_RevertApproveAndTransferFromToNonKYC() public {
        vm.prank(alice);
        vault.approve(bob, 1_000e6);

        vm.prank(bob);
        vm.expectRevert("BondVault: recipient not KYC");
        vault.transferFrom(alice, charlie, 1_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests : Pause
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
