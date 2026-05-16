// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrivoVault} from "../../src/treasury/BrivoVault.sol";
import {SubscriptionQueue} from "../../src/treasury/SubscriptionQueue.sol";
import {RedemptionQueue} from "../../src/treasury/RedemptionQueue.sol";
import {TreasuryFeeCollector} from "../../src/treasury/TreasuryFeeCollector.sol";
import {NAVOracle} from "../../src/treasury/NAVOracle.sol";
import {RescueManager} from "../../src/treasury/RescueManager.sol";
import {GlobalIdentityRegistry} from "../../src/treasury/compliance/GlobalIdentityRegistry.sol";
import {ProductEligibilityRegistry} from "../../src/treasury/compliance/ProductEligibilityRegistry.sol";
import {IGlobalIdentityRegistry} from "../../src/treasury/interfaces/IGlobalIdentityRegistry.sol";
import {IProductEligibilityRegistry} from "../../src/treasury/interfaces/IProductEligibilityRegistry.sol";
import {ITreasuryFeeCollector} from "../../src/treasury/interfaces/ITreasuryFeeCollector.sol";
import {TreasuryRoles} from "../../src/treasury/libraries/TreasuryRoles.sol";

import {MockToken} from "../../test/treasury/mocks/MockToken.sol";

/// @title Sepolia deploy script for the Brivo Treasury stack.
/// @notice Deploys MockUSDC / MockUSDY (testnet only) + the full Treasury
///         stack + wires up roles + registers the brvUSTY product.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   BRIVO_TREASURY_ADMIN_SEPOLIA       — admin EOA / Safe
///   BRIVO_TREASURY_KYC_OPERATOR_SEPOLIA — KYC backend
///   BRIVO_TREASURY_OPERATOR_SEPOLIA    — settlement Safe
///   BRIVO_TREASURY_OPERATOR_TREASURY_SEPOLIA — settlement custody Safe
///   BRIVO_TREASURY_RESCUER_SEPOLIA     — rescue council Safe
contract DeployTreasurySepolia is Script {
    bytes32 internal constant PRODUCT_ID = keccak256("brvUSTY");

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("BRIVO_TREASURY_ADMIN_SEPOLIA");
        address kycOperator = vm.envAddress("BRIVO_TREASURY_KYC_OPERATOR_SEPOLIA");
        address operator = vm.envAddress("BRIVO_TREASURY_OPERATOR_SEPOLIA");
        address opTreasury = vm.envAddress("BRIVO_TREASURY_OPERATOR_TREASURY_SEPOLIA");
        address rescuer = vm.envAddress("BRIVO_TREASURY_RESCUER_SEPOLIA");

        vm.startBroadcast(deployerPk);

        // 1. Mocks (real USDY is not on Sepolia)
        MockToken usdc = new MockToken("Mock USDC", "USDC", 6);
        MockToken usdy = new MockToken("Mock USDY", "USDY", 18);

        // 2. Compliance
        GlobalIdentityRegistry gir = new GlobalIdentityRegistry(admin, kycOperator);
        ProductEligibilityRegistry per = new ProductEligibilityRegistry(admin, gir, admin);

        // 3. Periphery
        TreasuryFeeCollector fees = new TreasuryFeeCollector(admin);
        NAVOracle oracle = new NAVOracle(admin);

        // 4. Vault
        BrivoVault vault = new BrivoVault(
            "Brivo US Treasury Yield",
            "brvUSTY",
            IERC20(address(usdy)),
            PRODUCT_ID,
            IProductEligibilityRegistry(address(per)),
            ITreasuryFeeCollector(address(fees)),
            admin,
            10_000_000e18, // 10M cap
            100e18          // 100 brvUSTY min
        );

        // 5. Queues
        SubscriptionQueue subQueue = new SubscriptionQueue(
            vault, IERC20(address(usdc)), IERC20(address(usdy)),
            opTreasury, admin, operator, 1 days
        );
        RedemptionQueue redQueue = new RedemptionQueue(
            vault, IERC20(address(usdc)),
            admin, operator, 1 days
        );

        // 6. Rescue manager
        RescueManager rescue = new RescueManager(
            vault, IProductEligibilityRegistry(address(per)),
            admin, rescuer
        );

        // 7. Wire up roles
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, address(subQueue));
        vault.grantRole(TreasuryRoles.VAULT_GATEWAY_ROLE, address(redQueue));
        vault.grantRole(TreasuryRoles.PAUSER_ROLE, address(rescue));
        vault.grantRole(TreasuryRoles.RESCUE_ROLE, address(rescue));
        per.grantRole(TreasuryRoles.PRODUCT_ADMIN_ROLE, address(rescue));
        fees.grantRole(TreasuryRoles.FEE_GATEWAY_ROLE, address(vault));
        fees.grantRole(TreasuryRoles.FEE_GATEWAY_ROLE, address(subQueue));
        fees.grantRole(TreasuryRoles.FEE_GATEWAY_ROLE, address(redQueue));

        // 8. Product registration
        per.registerProduct(
            PRODUCT_ID,
            address(vault),
            IGlobalIdentityRegistry.KycLevel.Basic,
            false
        );
        per.addAllowlistAccount(PRODUCT_ID, address(redQueue));

        // 9. Display NAV (testnet placeholder)
        oracle.setFallbackPrice(address(vault), 1.05e18);

        vm.stopBroadcast();

        // 10. Log addresses
        console2.log("=== Brivo Treasury — Sepolia deployment ===");
        console2.log("USDC (mock)              :", address(usdc));
        console2.log("USDY (mock)              :", address(usdy));
        console2.log("GlobalIdentityRegistry   :", address(gir));
        console2.log("ProductEligibilityRegistry:", address(per));
        console2.log("TreasuryFeeCollector     :", address(fees));
        console2.log("NAVOracle                :", address(oracle));
        console2.log("BrivoVault (brvUSTY)     :", address(vault));
        console2.log("SubscriptionQueue        :", address(subQueue));
        console2.log("RedemptionQueue          :", address(redQueue));
        console2.log("RescueManager            :", address(rescue));
    }
}
