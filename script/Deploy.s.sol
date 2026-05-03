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
 * @notice Script de déploiement de l'infrastructure Bondary v2 (Corporate Bond Tokenization).
 *
 * Pré-requis (variables d'environnement) :
 *   DEPLOYER_PRIVATE_KEY : clé privée du compte déployeur
 *   BONDARY_ADMIN        : adresse du Gnosis Safe (multisig 2/3 minimum)
 *
 * Ordre de déploiement :
 *   1. ComplianceManager   — registre KYC/AML global (remplace BondaryWhitelist)
 *   2. BondaryFeeCollector — collecteur de frais plateforme
 *   3. CorporateBond impl  — implémentation logique UUPS (jamais utilisée directement)
 *   4. BondFactory         — factory de proxies ERC1967
 *   5. BondaryMarketplace  — marché secondaire order book
 *   6. Whitelist le marketplace dans ComplianceManager (reçoit des security tokens)
 *
 * Usage :
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $POLYGON_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {
    // ─── Configuration plateforme ─────────────────────────────────────────────

    uint256 constant SETUP_FEE_BPS          = 100;  // 1.0% frais de dossier
    uint256 constant PLATFORM_COUPON_FEE_BPS = 50;  // 0.5% frais sur coupons/intérêts
    uint256 constant TRADING_FEE_BPS        = 50;   // 0.5% frais AMM
    uint256 constant EARLY_EXIT_PENALTY_BPS = 200;  // 2.0% pénalité sortie anticipée

    function run() external {
        address admin   = vm.envAddress("BONDARY_ADMIN");
        uint256 privKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(privKey);

        // 1. ComplianceManager (KYC/AML)
        ComplianceManager cm = new ComplianceManager(admin);
        console2.log("ComplianceManager  :", address(cm));

        // 2. Fee Collector
        BondaryFeeCollector fc = new BondaryFeeCollector(admin);
        console2.log("BondaryFeeCollector:", address(fc));

        // 3. CorporateBond implementation (logique uniquement, _disableInitializers())
        CorporateBond impl = new CorporateBond();
        console2.log("CorporateBond impl :", address(impl));

        // 4. BondFactory
        BondFactory factory = new BondFactory(admin, address(impl), address(cm), address(fc));
        console2.log("BondFactory        :", address(factory));

        // Grant factory DEFAULT_ADMIN_ROLE on feeCollector so it can auto-grant
        // AUTHORIZED_SOURCE_ROLE to each bond it deploys via createBond().
        fc.grantRole(fc.DEFAULT_ADMIN_ROLE(), address(factory));

        // 5. BondaryMarketplace
        BondaryMarketplace marketplace = new BondaryMarketplace(
            admin,
            address(cm),
            address(fc),
            address(factory),
            TRADING_FEE_BPS,
            EARLY_EXIT_PENALTY_BPS
        );
        console2.log("BondaryMarketplace :", address(marketplace));

        // 6. Whitelist le marketplace dans ComplianceManager
        //    (il reçoit des security tokens lors du séquestre des ordres)
        cm.whitelist(address(marketplace));
        console2.log("Marketplace whiteliste dans ComplianceManager");

        // 7. Autoriser le marketplace à notifier les frais dans FeeCollector
        fc.grantRole(fc.AUTHORIZED_SOURCE_ROLE(), address(marketplace));
        console2.log("Marketplace autorise dans BondaryFeeCollector");

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
