// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrivoVault} from "../../src/treasury/BrivoVault.sol";
import {RescueManager} from "../../src/treasury/RescueManager.sol";
import {GlobalIdentityRegistry} from "../../src/treasury/compliance/GlobalIdentityRegistry.sol";
import {ProductEligibilityRegistry} from "../../src/treasury/compliance/ProductEligibilityRegistry.sol";
import {IGlobalIdentityRegistry} from "../../src/treasury/interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../../src/treasury/interfaces/IProductEligibilityRegistry.sol";
import {IRescueManager} from "../../src/treasury/interfaces/IRescueManager.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "../../src/treasury/libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

import {MockToken} from "./mocks/MockToken.sol";

contract RescueManagerTest is Test {
    BrivoVault internal vault;
    RescueManager internal rescue;
    GlobalIdentityRegistry internal gir;
    ProductEligibilityRegistry internal per;
    MockToken internal usdy;

    address internal admin = makeAddr("admin");
    address internal kycOperator = makeAddr("kycOperator");
    address internal productAdmin = makeAddr("productAdmin");
    address internal rescuer = makeAddr("rescuer");
    address internal recipient = makeAddr("recipient");

    bytes32 internal constant PRODUCT_ID = keccak256("brvUSTY");

    function setUp() public {
        gir = new GlobalIdentityRegistry(admin, kycOperator);
        per = new ProductEligibilityRegistry(admin, gir, productAdmin);
        usdy = new MockToken("USDY", "USDY", 18);

        vault = new BrivoVault(
            "brvUSTY", "brvUSTY",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(0)),
            admin, 10_000_000e18, 100e18
        );

        rescue = new RescueManager(
            vault, IProductEligibilityRegistry(address(per)),
            admin, rescuer
        );

        vm.startPrank(admin);
        vault.grantRole(TreasuryRoles.PAUSER_ROLE, address(rescue));
        vault.grantRole(TreasuryRoles.RESCUE_ROLE, address(rescue));
        vm.stopPrank();

        vm.prank(productAdmin);
        per.registerProduct(
            PRODUCT_ID, address(vault),
            IGlobalIdentityRegistry.KycLevel.Basic, false
        );
        vm.prank(admin);
        per.grantRole(TreasuryRoles.PRODUCT_ADMIN_ROLE, address(rescue));
    }

    function _propose(IRescueManager.ProposalKind kind, bytes memory data)
        internal
        returns (bytes32)
    {
        vm.prank(rescuer);
        return rescue.propose(kind, data);
    }

    // ---------------- propose ----------------

    function test_propose_storesProposal() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        IRescueManager.Proposal memory p = rescue.proposalOf(id);
        assertEq(uint8(p.kind), uint8(IRescueManager.ProposalKind.PauseVault));
        assertEq(p.readyAt, p.proposedAt + 7 days);
        assertFalse(p.executed);
        assertFalse(p.cancelled);
    }

    function test_propose_revertsInvalidKind() public {
        vm.prank(rescuer);
        vm.expectRevert(TreasuryErrors.RescueInvalidKind.selector);
        rescue.propose(IRescueManager.ProposalKind.None, "");
    }

    function test_propose_onlyRescuer() public {
        vm.prank(admin);
        vm.expectRevert();
        rescue.propose(IRescueManager.ProposalKind.PauseVault, "");
    }

    // ---------------- execute / timelock ----------------

    function test_execute_revertsBeforeTimelock() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.prank(rescuer);
        vm.expectRevert();
        rescue.execute(id);
    }

    function test_execute_pauseVault() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        assertTrue(vault.paused());
    }

    function test_execute_unpauseVault() public {
        // first pause
        bytes32 id1 = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id1);
        assertTrue(vault.paused());

        // now unpause
        bytes32 id2 = _propose(IRescueManager.ProposalKind.UnpauseVault, "");
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id2);
        assertFalse(vault.paused());
    }

    function test_execute_freezeProduct() public {
        bytes32 id = _propose(
            IRescueManager.ProposalKind.FreezeProduct,
            abi.encode(PRODUCT_ID)
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        IProductEligibilityRegistry.ProductConfig memory cfg = per.configOf(PRODUCT_ID);
        assertEq(uint8(cfg.status), uint8(IProductEligibilityRegistry.ProductStatus.Frozen));
    }

    function test_execute_setHaircut() public {
        bytes32 id = _propose(
            IRescueManager.ProposalKind.SetEmergencyHaircutBps,
            abi.encode(uint16(300))
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        assertEq(rescue.emergencyHaircutBps(), 300);
    }

    function test_execute_setHaircut_revertsTooHigh() public {
        bytes32 id = _propose(
            IRescueManager.ProposalKind.SetEmergencyHaircutBps,
            abi.encode(uint16(600))
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.FeeTooHigh.selector, uint16(600), uint16(500))
        );
        rescue.execute(id);
    }

    function test_execute_reclaimExcess() public {
        // simulate over-delivery of underlying
        usdy.mint(address(vault), 1000e18);
        bytes32 id = _propose(
            IRescueManager.ProposalKind.ReclaimExcess,
            abi.encode(recipient)
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        assertEq(usdy.balanceOf(recipient), 1000e18);
    }

    function test_execute_unsupportedKind() public {
        bytes32 id = _propose(
            IRescueManager.ProposalKind.ForceRedeem,
            abi.encode(address(0), uint256(0), address(0))
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryErrors.RescueUnsupportedKind.selector,
                uint8(IRescueManager.ProposalKind.ForceRedeem)
            )
        );
        rescue.execute(id);
    }

    function test_execute_cannotExecuteTwice() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.RescueProposalAlreadyExecuted.selector, id)
        );
        rescue.execute(id);
    }

    function test_execute_revertsProposalNotFound() public {
        bytes32 fakeId = keccak256("nope");
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.RescueProposalNotFound.selector, fakeId)
        );
        rescue.execute(fakeId);
    }

    // ---------------- cancel ----------------

    function test_cancel_marksCancelled() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.prank(rescuer);
        rescue.cancel(id);
        IRescueManager.Proposal memory p = rescue.proposalOf(id);
        assertTrue(p.cancelled);
    }

    function test_cancel_blocksExecution() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.prank(rescuer);
        rescue.cancel(id);
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.RescueProposalCancelled.selector, id)
        );
        rescue.execute(id);
    }

    function test_cancel_revertsAfterExecute() public {
        bytes32 id = _propose(IRescueManager.ProposalKind.PauseVault, "");
        vm.warp(block.timestamp + 7 days);
        vm.prank(rescuer);
        rescue.execute(id);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryErrors.RescueProposalAlreadyExecuted.selector, id)
        );
        rescue.cancel(id);
    }
}
