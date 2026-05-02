// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Test", "TST") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Points de contrôle — BondaryFeeCollector
//
//  CP-FC-01  notifyFeeReceived() revert pour toute adresse non autorisée
//  CP-FC-02  admin peut accorder AUTHORIZED_SOURCE_ROLE
//  CP-FC-03  une source autorisée peut appeler notifyFeeReceived()
//  CP-FC-04  notifyFeeReceived() émet FeeReceived avec les bons paramètres
//  CP-FC-05  retrait du rôle bloque immédiatement notifyFeeReceived()
//  CP-FC-06  withdraw() transfère les tokens au destinataire
//  CP-FC-07  withdraw() revert pour non-WITHDRAWAL_ROLE
//  CP-FC-08  balance() retourne le solde ERC20 correct
//  CP-FC-09  admin est à la fois DEFAULT_ADMIN et WITHDRAWAL à la construction
// ─────────────────────────────────────────────────────────────────────────────

contract FeeCollectorACLTest is Test {
    address internal admin   = makeAddr("admin");
    address internal vault1  = makeAddr("vault1");
    address internal vault2  = makeAddr("vault2");
    address internal random  = makeAddr("random");
    address internal treasury = makeAddr("treasury");

    BondaryFeeCollector internal fc;
    MockToken           internal token;

    function setUp() public {
        fc    = new BondaryFeeCollector(admin);
        token = new MockToken();
    }

    // CP-FC-01  Appel sans rôle → revert
    function test_UnauthorizedCannotCallNotify() public {
        vm.prank(random);
        vm.expectRevert();
        fc.notifyFeeReceived(address(token), 1_000e6, BondaryFeeCollector.FeeType.SETUP);
    }

    // CP-FC-01b  Admin lui-même sans le rôle SOURCE ne peut pas appeler
    function test_AdminWithoutSourceRoleCannotCallNotify() public {
        vm.prank(admin);
        vm.expectRevert();
        fc.notifyFeeReceived(address(token), 500e6, BondaryFeeCollector.FeeType.INTEREST);
    }

    // CP-FC-02  Admin peut accorder AUTHORIZED_SOURCE_ROLE
    function test_AdminCanGrantSourceRole() public {
        vm.prank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);
        assertTrue(fc.hasRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1));
    }

    // CP-FC-03  Source autorisée peut appeler notifyFeeReceived() sans revert
    function test_AuthorizedSourceCanNotify() public {
        vm.prank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);

        vm.prank(vault1);
        fc.notifyFeeReceived(address(token), 2_000e6, BondaryFeeCollector.FeeType.MARKETPLACE);
    }

    // CP-FC-04  notifyFeeReceived() émet FeeReceived avec les bons arguments
    function test_NotifyEmitsFeeReceived() public {
        vm.prank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);

        vm.expectEmit(true, true, false, true, address(fc));
        emit BondaryFeeCollector.FeeReceived(
            vault1,
            address(token),
            1_500e6,
            BondaryFeeCollector.FeeType.PENALTY
        );

        vm.prank(vault1);
        fc.notifyFeeReceived(address(token), 1_500e6, BondaryFeeCollector.FeeType.PENALTY);
    }

    // CP-FC-05  Révocation du rôle bloque immédiatement
    function test_RevokedSourceCannotNotify() public {
        vm.startPrank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);
        fc.revokeRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);
        vm.stopPrank();

        vm.prank(vault1);
        vm.expectRevert();
        fc.notifyFeeReceived(address(token), 100e6, BondaryFeeCollector.FeeType.SETUP);
    }

    // CP-FC-05b  Deux sources indépendantes : révoquer l'une ne bloque pas l'autre
    function test_RevokingOneSourceDoesNotAffectOther() public {
        vm.startPrank(admin);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), vault2);
        fc.revokeRole(fc.AUTHORIZED_SOURCE_ROLE(), vault1);
        vm.stopPrank();

        // vault2 toujours autorisé
        vm.prank(vault2);
        fc.notifyFeeReceived(address(token), 100e6, BondaryFeeCollector.FeeType.SETUP);
    }

    // CP-FC-06  withdraw() transfère correctement les tokens
    function test_WithdrawTransfersTokens() public {
        token.mint(address(fc), 10_000e6);

        uint256 before = token.balanceOf(treasury);
        vm.prank(admin);
        fc.withdraw(address(token), treasury, 10_000e6);

        assertEq(token.balanceOf(treasury) - before, 10_000e6);
        assertEq(token.balanceOf(address(fc)), 0);
    }

    // CP-FC-07  withdraw() revert pour non-WITHDRAWAL_ROLE
    function test_WithdrawRevertsForUnauthorized() public {
        token.mint(address(fc), 10_000e6);
        vm.prank(random);
        vm.expectRevert();
        fc.withdraw(address(token), random, 10_000e6);
    }

    // CP-FC-08  balance() retourne le solde ERC20 exact
    function test_BalanceReturnsCorrectValue() public {
        token.mint(address(fc), 7_500e6);
        assertEq(fc.balance(address(token)), 7_500e6);
    }

    // CP-FC-09  Admin a WITHDRAWAL_ROLE à la construction
    function test_AdminHasWithdrawalRoleAtConstruction() public view {
        assertTrue(fc.hasRole(fc.WITHDRAWAL_ROLE(), admin));
    }

    // CP-FC-09b  Admin a DEFAULT_ADMIN_ROLE à la construction
    function test_AdminHasDefaultAdminAtConstruction() public view {
        assertTrue(fc.hasRole(fc.DEFAULT_ADMIN_ROLE(), admin));
    }
}
