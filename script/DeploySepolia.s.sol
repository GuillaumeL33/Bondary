// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CorporateBond} from "../src/CorporateBond.sol";
import {BondFactory} from "../src/BondFactory.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockEURC} from "../src/mocks/MockEURC.sol";

/**
 * @title DeploySepolia
 * @notice Full Sepolia testnet deployment including MockUSDC / MockEURC.
 *
 *   Required env vars:
 *     SEPOLIA_RPC_URL         : Sepolia RPC (Alchemy / Infura / Ankr)
 *     DEPLOYER_PRIVATE_KEY    : Deployer EOA (testnet)
 *     BONDARY_ADMIN_SEPOLIA   : Admin (EOA acceptable on testnet)
 *     ETHERSCAN_API_KEY       : For contract verification
 *
 *   Usage:
 *     forge script script/DeploySepolia.s.sol \
 *       --rpc-url $SEPOLIA_RPC_URL \
 *       --broadcast \
 *       --verify \
 *       -vvvv
 *
 *   Output (copy to dapp/.env.local):
 *     NEXT_PUBLIC_USDC_ADDRESS                    = MockUSDC
 *     NEXT_PUBLIC_EURC_ADDRESS                    = MockEURC
 *     NEXT_PUBLIC_BONDARY_COMPLIANCE_ADDRESS      = ComplianceManager
 *     NEXT_PUBLIC_BONDARY_FEE_COLLECTOR_ADDRESS   = BondaryFeeCollector
 *     NEXT_PUBLIC_BONDARY_FACTORY_ADDRESS         = BondFactory
 *     NEXT_PUBLIC_BONDARY_MARKETPLACE_ADDRESS     = BondaryMarketplace
 *
 *   Sepolia faucets:
 *     - https://sepoliafaucet.com
 *     - https://www.infura.io/faucet/sepolia
 *     - https://faucet.quicknode.com/ethereum/sepolia
 */
contract DeploySepolia is Script {
    uint256 constant SETUP_FEE_BPS           = 100;  // 1.0%
    uint256 constant PLATFORM_COUPON_FEE_BPS = 50;   // 0.5%
    uint256 constant TRADING_FEE_BPS         = 50;   // 0.5%
    uint256 constant EARLY_EXIT_PENALTY_BPS  = 200;  // 2.0%

    function run() external {
        address admin   = vm.envAddress("BONDARY_ADMIN_SEPOLIA");
        uint256 privKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(privKey);

        // 1. Mock payment tokens (testnet only)
        MockUSDC usdc = new MockUSDC();
        console2.log("MockUSDC           :", address(usdc));
        MockEURC eurc = new MockEURC();
        console2.log("MockEURC           :", address(eurc));

        // 2. Compliance + Fee collector
        ComplianceManager cm = new ComplianceManager(admin);
        console2.log("ComplianceManager  :", address(cm));
        BondaryFeeCollector fc = new BondaryFeeCollector(admin);
        console2.log("BondaryFeeCollector:", address(fc));

        // 3. CorporateBond implementation
        CorporateBond impl = new CorporateBond();
        console2.log("CorporateBond impl :", address(impl));

        // 4. BondFactory
        BondFactory factory = new BondFactory(admin, address(impl), address(cm), address(fc));
        console2.log("BondFactory        :", address(factory));

        // 5. Marketplace
        BondaryMarketplace marketplace = new BondaryMarketplace(
            admin, address(cm), address(fc), address(factory),
            TRADING_FEE_BPS, EARLY_EXIT_PENALTY_BPS
        );
        console2.log("BondaryMarketplace :", address(marketplace));

        // 6. Wire roles
        fc.grantRole(fc.DEFAULT_ADMIN_ROLE(), address(factory));
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), address(marketplace));
        // S-05 : factory can bind new bonds.
        cm.grantRole(cm.COMPLIANCE_ADMIN_ROLE(), address(factory));

        // 7. Whitelist marketplace + admin
        cm.whitelist(address(marketplace));
        cm.whitelist(admin);

        vm.stopBroadcast();

        _logSummary(
            admin,
            address(usdc),
            address(eurc),
            address(cm),
            address(fc),
            address(impl),
            address(factory),
            address(marketplace)
        );
    }

    function _logSummary(
        address admin,
        address usdc,
        address eurc,
        address cm,
        address fc,
        address impl,
        address factory,
        address marketplace
    ) internal pure {
        console2.log("\n=== BONDARY SEPOLIA DEPLOYMENT SUMMARY ===");
        console2.log("Admin                  :", admin);
        console2.log("MockUSDC               :", usdc);
        console2.log("MockEURC               :", eurc);
        console2.log("ComplianceManager      :", cm);
        console2.log("BondaryFeeCollector    :", fc);
        console2.log("CorporateBond impl     :", impl);
        console2.log("BondFactory            :", factory);
        console2.log("BondaryMarketplace     :", marketplace);
        console2.log("==========================================\n");
        console2.log("=== Copy to dapp/.env.local ===");
        console2.log("NEXT_PUBLIC_CHAIN_ID=11155111");
        console2.log("NEXT_PUBLIC_USDC_ADDRESS=", usdc);
        console2.log("NEXT_PUBLIC_EURC_ADDRESS=", eurc);
        console2.log("NEXT_PUBLIC_BONDARY_COMPLIANCE_ADDRESS=", cm);
        console2.log("NEXT_PUBLIC_BONDARY_FEE_COLLECTOR_ADDRESS=", fc);
        console2.log("NEXT_PUBLIC_BONDARY_FACTORY_ADDRESS=", factory);
        console2.log("NEXT_PUBLIC_BONDARY_MARKETPLACE_ADDRESS=", marketplace);
        console2.log("================================");
    }
}
