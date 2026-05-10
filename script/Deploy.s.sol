// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CorporateBond} from "../src/CorporateBond.sol";
import {BondFactory} from "../src/BondFactory.sol";
import {ComplianceManager} from "../src/ComplianceManager.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";

/**
 * @title Deploy
 * @notice Deploy the Bondary stack on mainnet networks (Polygon / Ethereum).
 *         For Sepolia testnet, use DeploySepolia.s.sol which also deploys
 *         MockUSDC / MockEURC.
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY : deployer private key
 *   BONDARY_ADMIN        : Gnosis Safe address (≥2/3 multisig)
 *
 * Deployment order:
 *   1. ComplianceManager   — KYC/AML registry
 *   2. BondaryFeeCollector — platform fee collector
 *   3. CorporateBond impl  — UUPS implementation (never used directly)
 *   4. BondFactory         — ERC1967 proxy factory
 *   5. BondaryMarketplace  — secondary order book
 *   6. Whitelist marketplace in ComplianceManager
 *   7. Grant COMPLIANCE_ADMIN_ROLE to factory (S-05: it binds new bonds)
 *   8. Grant DEFAULT_ADMIN_ROLE to factory on FeeCollector (auto-grants bonds)
 *   9. Grant AUTHORIZED_SOURCE_ROLE to marketplace
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $POLYGON_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {
    uint256 constant SETUP_FEE_BPS           = 100;  // 1.0%
    uint256 constant PLATFORM_COUPON_FEE_BPS = 50;   // 0.5%
    uint256 constant TRADING_FEE_BPS         = 50;   // 0.5%
    uint256 constant EARLY_EXIT_PENALTY_BPS  = 200;  // 2.0%

    function run() external {
        address admin   = vm.envAddress("BONDARY_ADMIN");
        uint256 privKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(privKey);

        ComplianceManager cm = new ComplianceManager(admin);
        console2.log("ComplianceManager  :", address(cm));

        BondaryFeeCollector fc = new BondaryFeeCollector(admin);
        console2.log("BondaryFeeCollector:", address(fc));

        CorporateBond impl = new CorporateBond();
        console2.log("CorporateBond impl :", address(impl));

        BondFactory factory = new BondFactory(admin, address(impl), address(cm), address(fc));
        console2.log("BondFactory        :", address(factory));

        // Factory can grant AUTHORIZED_SOURCE_ROLE to bonds it deploys.
        fc.grantRole(fc.DEFAULT_ADMIN_ROLE(), address(factory));

        // S-05 : factory can bind new bonds on ComplianceManager.
        cm.grantRole(cm.COMPLIANCE_ADMIN_ROLE(), address(factory));

        BondaryMarketplace marketplace = new BondaryMarketplace(
            admin, address(cm), address(fc), address(factory),
            TRADING_FEE_BPS, EARLY_EXIT_PENALTY_BPS
        );
        console2.log("BondaryMarketplace :", address(marketplace));

        cm.whitelist(address(marketplace));
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), address(marketplace));

        vm.stopBroadcast();

        _logSummary(admin, address(cm), address(fc), address(impl), address(factory), address(marketplace));
    }

    function _logSummary(
        address admin,
        address cm,
        address fc,
        address impl,
        address factory,
        address marketplace
    ) internal pure {
        console2.log("\n=== BONDARY V2 DEPLOYMENT SUMMARY ===");
        console2.log("Admin (Gnosis Safe)    :", admin);
        console2.log("ComplianceManager      :", cm);
        console2.log("BondaryFeeCollector    :", fc);
        console2.log("CorporateBond impl     :", impl);
        console2.log("BondFactory            :", factory);
        console2.log("BondaryMarketplace     :", marketplace);
        console2.log("=====================================\n");
        console2.log("NEXT STEPS:");
        console2.log("1. Grant KYC_OPERATOR_ROLE to your KYC backend wallet");
        console2.log("2. Grant BOND_CREATOR_ROLE to your ops wallet (or Gnosis Safe)");
        console2.log("3. Connect KYC provider (Fractal/Synaps) to KYC operator wallet");
        console2.log("4. For each new bond: call factory.createBond(name, symbol, terms, ...)");
    }
}
