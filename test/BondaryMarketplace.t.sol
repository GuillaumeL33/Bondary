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

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MarketplaceTest is Test {
    address internal admin    = makeAddr("admin");
    address internal borrower = makeAddr("borrower");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal charlie  = makeAddr("charlie"); // non-KYC

    MockUSDC2           internal usdc;
    BondaryWhitelist    internal wl;
    BondaryFeeCollector internal fc;
    BondVaultFactory    internal factory;
    BondaryMarketplace  internal marketplace;
    BondVault           internal vault;

    uint256 internal constant TRADING_FEE_BPS  = 50;   // 0.5 %
    uint256 internal constant PENALTY_BPS      = 200;  // 2 %
    uint256 internal subscriptionEnd;

    function setUp() public {
        usdc = new MockUSDC2();
        wl   = new BondaryWhitelist(admin);
        fc   = new BondaryFeeCollector(admin);

        // Factory
        address vaultImpl = address(new BondVault());
        factory = new BondVaultFactory(admin, vaultImpl);

        // Marketplace
        marketplace = new BondaryMarketplace(
            admin,
            address(wl),
            address(fc),
            address(factory),
            TRADING_FEE_BPS,
            PENALTY_BPS
        );

        // KYC : alice, bob et le marketplace lui-même (security token)
        vm.startPrank(admin);
        wl.whitelist(alice);
        wl.whitelist(bob);
        wl.whitelist(address(marketplace)); // le contrat marketplace doit recevoir les parts
        vm.stopPrank();

        // Créer un vault via la factory
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
            address(usdc),
            "Bondary Bond 2027",
            "BND27",
            params,
            admin
        );
        vault = BondVault(vaultAddr);

        // Fonds — bob a besoin de suffisamment pour acheter les parts d'alice au prix majoré
        usdc.mint(alice,    200_000e6);
        usdc.mint(bob,      300_000e6);
        usdc.mint(borrower, 500_000e6);

        // Alice dépose dans le vault
        vm.startPrank(alice);
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, alice);
        vm.stopPrank();

        // Activation du prêt
        vm.warp(subscriptionEnd + 1);
        vm.prank(admin);
        vault.activateLoan();

        // Emprunteur tire les fonds
        uint256 available = usdc.balanceOf(address(vault));
        vm.prank(borrower);
        vault.drawLoan(available);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Test : création d'un ordre
    // ─────────────────────────────────────────────────────────────────────────

    function test_CreateSellOrder() public {
        uint256 shares     = vault.balanceOf(alice);
        uint256 price      = 1_050_000; // 1.05 USDC par part

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, price);
        vm.stopPrank();

        BondaryMarketplace.Order memory order = marketplace.getOrder(orderId);
        assertEq(order.seller,       alice);
        assertEq(order.shares,       shares);
        assertEq(order.pricePerShare, price);
        assertTrue(order.active);

        // Les parts sont séquestrées dans le marketplace
        assertEq(vault.balanceOf(address(marketplace)), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_RevertCreateOrderIfNotKYC() public {
        usdc.mint(charlie, 10_000e6);
        vm.prank(charlie);
        vm.expectRevert("Marketplace: seller not KYC");
        marketplace.createSellOrder(address(vault), 1_000e6, 1_000_000);
    }

    function test_RevertCreateOrderIfNotOfficialVault() public {
        address fakeVault = makeAddr("fakeVault");
        vm.prank(alice);
        vm.expectRevert("Marketplace: not official vault");
        marketplace.createSellOrder(fakeVault, 1_000e6, 1_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Test : exécution d'un ordre (early exit = pénalité appliquée)
    // ─────────────────────────────────────────────────────────────────────────

    function test_FillOrderWithEarlyExitPenalty() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 price  = 1_050_000; // 1.05 USDC / part

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, price);
        vm.stopPrank();

        // totalCost = shares * price / 10^6
        uint256 totalCost  = (shares * price) / 1e6;
        uint256 tradingFee = (totalCost * TRADING_FEE_BPS) / 10_000;
        uint256 penalty    = (totalCost * PENALTY_BPS) / 10_000;

        uint256 aliceBefore  = usdc.balanceOf(alice);
        uint256 fcBefore     = usdc.balanceOf(address(fc));

        vm.startPrank(bob);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        // Alice reçoit le montant net
        assertEq(usdc.balanceOf(alice) - aliceBefore, totalCost - tradingFee - penalty);
        // FeeCollector reçoit les frais
        assertEq(usdc.balanceOf(address(fc)) - fcBefore, tradingFee + penalty);
        // Bob reçoit les parts
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_FillOrderNoEarlyPenaltyAfterMaturity() public {
        // Avancer jusqu'après la maturité
        vm.warp(block.timestamp + 365 days + 1);

        uint256 shares = vault.balanceOf(alice);
        uint256 price  = 1_080_000;

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, price);
        vm.stopPrank();

        uint256 totalCost  = (shares * price) / 1e6;
        uint256 tradingFee = (totalCost * TRADING_FEE_BPS) / 10_000;
        // Pas de pénalité après maturité

        uint256 fcBefore = usdc.balanceOf(address(fc));

        vm.startPrank(bob);
        usdc.approve(address(marketplace), totalCost);
        marketplace.fillOrder(orderId);
        vm.stopPrank();

        // Seul le tradingFee est prélevé
        assertEq(usdc.balanceOf(address(fc)) - fcBefore, tradingFee);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Test : annulation d'un ordre
    // ─────────────────────────────────────────────────────────────────────────

    function test_CancelOrder() public {
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, 1_050_000);
        marketplace.cancelOrder(orderId);
        vm.stopPrank();

        assertFalse(marketplace.getOrder(orderId).active);
        assertEq(vault.balanceOf(alice), shares); // parts restituées
    }

    function test_RevertFillCancelledOrder() public {
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, 1_050_000);
        marketplace.cancelOrder(orderId);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(marketplace), 200_000e6);
        vm.expectRevert("Marketplace: order not active");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_RevertFillIfBuyerNotKYC() public {
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, 1_050_000);
        vm.stopPrank();

        usdc.mint(charlie, 300_000e6);
        vm.startPrank(charlie);
        usdc.approve(address(marketplace), 300_000e6);
        vm.expectRevert("Marketplace: buyer not KYC");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    function test_RevertSelfTrade() public {
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.approve(address(marketplace), shares);
        uint256 orderId = marketplace.createSellOrder(address(vault), shares, 1_000_000);
        usdc.approve(address(marketplace), 200_000e6);
        vm.expectRevert("Marketplace: self-trade");
        marketplace.fillOrder(orderId);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Test : mise à jour des frais
    // ─────────────────────────────────────────────────────────────────────────

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
}
