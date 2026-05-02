// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BondVault} from "../src/BondVault.sol";
import {BondVaultFactory} from "../src/BondVaultFactory.sol";
import {BondaryWhitelist} from "../src/BondaryWhitelist.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Base fixture
// ─────────────────────────────────────────────────────────────────────────────

contract MarketplaceTest is Test {
    address internal admin    = makeAddr("admin");
    address internal borrower = makeAddr("borrower");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal charlie  = makeAddr("charlie"); // non-KYC
    address internal diana    = makeAddr("diana");   // KYC, used as recovery target

    MockUSDC2           internal usdc;
    BondaryWhitelist    internal wl;
    BondaryFeeCollector internal fc;
    BondVaultFactory    internal factory;
    BondaryMarketplace  internal marketplace;
    BondVault           internal vault;

    uint256 internal constant TRADING_FEE_BPS = 50;
    uint256 internal constant PENALTY_BPS     = 200;
    uint256 internal subscriptionEnd;

    function setUp() public {
        usdc = new MockUSDC2();
        wl   = new BondaryWhitelist(admin);
        fc   = new BondaryFeeCollector(admin);

        address vaultImpl = address(new BondVault());
        factory = new BondVaultFactory(admin, vaultImpl);

        marketplace = new BondaryMarketplace(
            admin,
            address(wl),
            address(fc),
            address(factory),
            TRADING_FEE_BPS,
            PENALTY_BPS
        );

        vm.startPrank(admin);
        wl.whitelist(alice);
        wl.whitelist(bob);
        wl.whitelist(diana);
        wl.whitelist(address(marketplace));
        vm.stopPrank();

        subscriptionEnd = block.timestamp + 30 days;
        BondVault.VaultParams memory params = BondVault.VaultParams({
            interestRateBps:        800,
            platformInterestFeeBps: 1_000,
            setupFeeBps:            100,
            softCap:                100_000e6,
            hardCap:                500_000e6,
            minDeposit:             50e6,
            subscriptionEnd:        subscriptionEnd,
            loanDuration:           365 days,
            gracePeriod:            30 days,
            borrower:               borrower,
            whitelistAddr:          address(wl),
            feeCollectorAddr:       address(fc)
        });

        vm.prank(admin);
        address vaultAddr = factory.createVault(
            address(usdc), "Bondary Bond 2027", "BND27", params, admin
        );
        vault = BondVault(vaultAddr);

        // Grant AUTHORIZED_SOURCE_ROLE to vault + marketplace
        vm.startPrank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vaultAddr);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), address(marketplace));
        vm.stopPrank();

        usdc.mint(alice,    200_000e6);
        usdc.mint(bob,      300_000e6);
        usdc.mint(borrower, 500_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, alice);
        vm.stopPrank();

        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vault.activateLoan();

        uint256 available = usdc.balanceOf(address(vault));
        vm.prank(borrower);
        vault.drawLoan(available);
    }

    function _createAliceOrder(uint256 price) internal returns (uint256 orderId) {
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        orderId = marketplace.createSellOrder(address(vault), shares, price);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [1] Création d'ordre
// ─────────────────────────────────────────────────────────────────────────────

contract OrderCreationTest is MarketplaceTest {
    function test_CreateSellOrder() public {
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, 1_050_000);
        vm.stopPrank();

        BondaryMarketplace.Order memory order = marketplace.getOrder(orderId);
        assertEq(order.seller, alice);
        assertEq(order.shares, shares);
        assertTrue(order.active);
        assertEq(vault.balanceOf(address(marketplace)), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_RevertCreateOrderIfNotKYC() public {
        vm.prank(charlie);
        vm.expectRevert("Marketplace: seller not KYC");
        marketplace.createSellOrder(address(vault), 1_000e6, 1_000_000);
    }

    function test_RevertCreateOrderIfNotOfficialVault() public {
        vm.prank(alice);
        vm.expectRevert("Marketplace: not official vault");
        marketplace.createSellOrder(makeAddr("fakeVault"), 1_000e6, 1_000_000);
    }

    function test_RevertCreateOrderZeroShares() public {
        vm.prank(alice);
        vm.expectRevert("Marketplace: zero shares");
        marketplace.createSellOrder(address(vault), 0, 1_000_000);
    }

    function test_RevertCreateOrderZeroPrice() public {
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        vm.expectRevert("Marketplace: zero price");
        marketplace.createSellOrder(address(vault), shares, 0);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [2] Exécution d'ordre
// ─────────────────────────────────────────────────────────────────────────────

contract OrderFillingTest is MarketplaceTest {
    function test_FillOrderWithEarlyExitPenalty() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 price  = 1_050_000;
        uint256 orderId = _createAliceOrder(price);

        uint256 totalCost  = (shares * price) / 1e6;
        uint256 tradingFee = (totalCost * TRADING_FEE_BPS) / 10_000;
        uint256 penalty    = (totalCost * PENALTY_BPS) / 10_000;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 fcBefore    = usdc.balanceOf(address(fc));

        vm.startPrank(bob);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceBefore, totalCost - tradingFee - penalty);
        assertEq(usdc.balanceOf(address(fc)) - fcBefore, tradingFee + penalty);
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_FillOrderNoEarlyPenaltyAfterMaturity() public {
        vm.warp(block.timestamp + 365 days + 1);
        uint256 shares  = vault.balanceOf(alice);
        uint256 price   = 1_080_000;
        uint256 orderId = _createAliceOrder(price);

        uint256 totalCost  = (shares * price) / 1e6;
        uint256 tradingFee = (totalCost * TRADING_FEE_BPS) / 10_000;
        uint256 fcBefore   = usdc.balanceOf(address(fc));

        vm.startPrank(bob);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(fc)) - fcBefore, tradingFee);
    }

    function test_RevertFillIfBuyerNotKYC() public {
        uint256 orderId = _createAliceOrder(1_050_000);
        usdc.mint(charlie, 300_000e6);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), 300_000e6);
        vm.expectRevert("Marketplace: buyer not KYC");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_RevertSelfTrade() public {
        uint256 orderId = _createAliceOrder(1_000_000);
        vm.startPrank(alice);
        usdc.approve(address(marketplace), 200_000e6);
        vm.expectRevert("Marketplace: self-trade");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_RevertFillInactiveOrder() public {
        uint256 orderId = _createAliceOrder(1_050_000);
        vm.prank(alice);
        marketplace.cancelOrder(orderId);
        vm.startPrank(bob);
        usdc.approve(address(marketplace), 300_000e6);
        vm.expectRevert("Marketplace: order not active");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [3] Annulation d'ordre
// ─────────────────────────────────────────────────────────────────────────────

contract OrderCancellationTest is MarketplaceTest {
    function test_SellerCanCancelOrder() public {
        uint256 shares  = vault.balanceOf(alice);
        uint256 orderId = _createAliceOrder(1_050_000);
        vm.prank(alice);
        marketplace.cancelOrder(orderId);
        assertFalse(marketplace.getOrder(orderId).active);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_AdminCanCancelOrder() public {
        _createAliceOrder(1_050_000);
        vm.prank(admin);
        marketplace.cancelOrder(0);
        assertFalse(marketplace.getOrder(0).active);
    }

    function test_RevertCancelByUnauthorized() public {
        _createAliceOrder(1_050_000);
        vm.prank(charlie);
        vm.expectRevert("Marketplace: not authorized");
        marketplace.cancelOrder(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [4] recoverEscrowedShares — bug KYC révoqué (audit fix)
//
//  CP-MKT-01  Démontre le bug : cancelOrder revert si vendeur révoqué
//  CP-MKT-02  recoverEscrowedShares réussit (happy path)
//  CP-MKT-03  Émet EscrowedSharesRecovered avec bons arguments
//  CP-MKT-04  Revert si vendeur toujours KYC
//  CP-MKT-05  Revert si appelant non-ADMIN
//  CP-MKT-06  Revert si ordre inactif
//  CP-MKT-07  Revert si newRecipient = address(0)
//  CP-MKT-08  Revert si newRecipient non KYC
//  CP-MKT-09  L'ordre est marqué inactif après récupération
// ─────────────────────────────────────────────────────────────────────────────

contract KYCRecoveryTest is MarketplaceTest {
    uint256 internal orderId;
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();
        aliceShares = vault.balanceOf(alice);
        orderId = _createAliceOrder(1_050_000);
        // Révoquer le KYC d'alice après qu'elle a créé l'ordre
        vm.prank(admin);
        wl.revoke(alice);
    }

    // CP-MKT-01  Preuve du bug : cancelOrder + admin cancel reverts tous les deux
    function test_BugProof_CancelOrderRevertsWhenSellerRevoked() public {
        // Seller self-cancel revert (KYC check sur transfer vers alice)
        vm.prank(alice);
        vm.expectRevert("BondVault: recipient not KYC");
        marketplace.cancelOrder(orderId);

        // Admin cancel revert aussi (même destination = alice révoquée)
        vm.prank(admin);
        vm.expectRevert("BondVault: recipient not KYC");
        marketplace.cancelOrder(orderId);
    }

    // CP-MKT-02  recoverEscrowedShares transfère les parts à diana (KYC)
    function test_RecoverEscrowedSharesHappyPath() public {
        vm.prank(admin);
        marketplace.recoverEscrowedShares(orderId, diana);

        assertEq(vault.balanceOf(diana), aliceShares);
        assertEq(vault.balanceOf(address(marketplace)), 0);
    }

    // CP-MKT-03  Émet EscrowedSharesRecovered
    function test_RecoverEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(marketplace));
        emit BondaryMarketplace.EscrowedSharesRecovered(
            orderId, alice, diana, aliceShares
        );
        vm.prank(admin);
        marketplace.recoverEscrowedShares(orderId, diana);
    }

    // CP-MKT-04  Revert si vendeur encore KYC (utiliser cancelOrder normal)
    function test_RevertRecoverIfSellerStillKYC() public {
        // Re-whitelister alice
        vm.prank(admin);
        wl.whitelist(alice);

        vm.prank(admin);
        vm.expectRevert("Marketplace: seller still KYC — use cancelOrder");
        marketplace.recoverEscrowedShares(orderId, diana);
    }

    // CP-MKT-05  Revert si appelant non-ADMIN
    function test_RevertRecoverIfNotAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        marketplace.recoverEscrowedShares(orderId, diana);
    }

    // CP-MKT-06  Revert si ordre inactif
    function test_RevertRecoverIfOrderInactive() public {
        // D'abord re-KYC alice pour pouvoir annuler l'ordre
        vm.prank(admin);
        wl.whitelist(alice);
        vm.prank(admin);
        marketplace.cancelOrder(orderId);

        // Re-révoquer et tenter recover sur ordre inactif
        vm.prank(admin);
        wl.revoke(alice);
        vm.prank(admin);
        vm.expectRevert("Marketplace: order not active");
        marketplace.recoverEscrowedShares(orderId, diana);
    }

    // CP-MKT-07  Revert si newRecipient = address(0)
    function test_RevertRecoverZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: zero recipient");
        marketplace.recoverEscrowedShares(orderId, address(0));
    }

    // CP-MKT-08  Revert si newRecipient non KYC
    function test_RevertRecoverIfRecipientNotKYC() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: recipient not KYC");
        marketplace.recoverEscrowedShares(orderId, charlie);
    }

    // CP-MKT-09  L'ordre est marqué inactif après recover
    function test_OrderMarkedInactiveAfterRecovery() public {
        vm.prank(admin);
        marketplace.recoverEscrowedShares(orderId, diana);
        assertFalse(marketplace.getOrder(orderId).active);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  [5] Admin & frais
// ─────────────────────────────────────────────────────────────────────────────

contract MarketplaceAdminTest is MarketplaceTest {
    function test_AdminCanUpdateFees() public {
        vm.prank(admin);
        marketplace.updateFees(100, 300);
        assertEq(marketplace.tradingFeeBps(), 100);
        assertEq(marketplace.earlyExitPenaltyBps(), 300);
    }

    function test_RevertFeesTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: trading fee too high");
        marketplace.updateFees(1_001, 0);
    }

    function test_RevertPenaltyTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: penalty too high");
        marketplace.updateFees(0, 1_001);
    }

    function test_PauseBlocksCreateOrder() public {
        vm.prank(admin);
        marketplace.pause();
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        vm.expectRevert();
        marketplace.createSellOrder(address(vault), shares, 1_050_000);
        vm.stopPrank();
    }
}
