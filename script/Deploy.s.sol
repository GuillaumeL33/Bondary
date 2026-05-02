// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BondVault} from "../src/BondVault.sol";
import {BondVaultFactory} from "../src/BondVaultFactory.sol";
import {BondaryWhitelist} from "../src/BondaryWhitelist.sol";
import {BondaryFeeCollector} from "../src/BondaryFeeCollector.sol";
import {BondaryMarketplace} from "../src/BondaryMarketplace.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deploy
 * @notice Script de déploiement de l'infrastructure Bondary.
 *
 * Pré-requis :
 *   - DEPLOYER_PRIVATE_KEY : clé privée du compte déployeur
 *   - BONDARY_ADMIN        : adresse du Gnosis Safe (multisig 2/3 minimum)
 *   - ASSET_TOKEN          : adresse EURC ou USDC sur le réseau cible
 *
 * Ordre de déploiement :
 *   1. BondaryWhitelist    — registre KYC global
 *   2. BondaryFeeCollector — collecteur de frais plateforme
 *   3. BondVault (impl)    — implémentation logique (pas directement utilisée)
 *   4. BondVaultFactory    — factory de proxies ERC1967
 *   5. BondaryMarketplace  — marché secondaire
 *   6. Whitelist le marketplace dans BondaryWhitelist (security token)
 *
 * Usage :
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $POLYGON_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {
    // ─── Configuration à adapter selon le réseau ──────────────────────────

    // Polygon : USDC 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
    // Polygon : EURC 0xc2132D05D31c914a87C6611C10748AEb04B58e8F (USDT, pas EURC)
    // Ethereum mainnet : USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // Ethereum mainnet : EURC 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c

    uint256 constant TRADING_FEE_BPS    = 50;   // 0.5 % frais AMM
    uint256 constant EARLY_EXIT_PENALTY = 200;  // 2.0 % pénalité sortie anticipée

    function run() external {
        address admin  = vm.envAddress("BONDARY_ADMIN");
        address asset  = vm.envAddress("ASSET_TOKEN");
        uint256 privKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(privKey);

        // 1. Whitelist KYC
        BondaryWhitelist wl = new BondaryWhitelist(admin);
        console2.log("BondaryWhitelist  :", address(wl));

        // 2. Fee Collector
        BondaryFeeCollector fc = new BondaryFeeCollector(admin);
        console2.log("BondaryFeeCollector:", address(fc));

        // 3. Vault implementation (logique uniquement, pas d'utilisation directe)
        BondVault impl = new BondVault();
        console2.log("BondVault impl    :", address(impl));

        // 4. Factory
        BondVaultFactory factory = new BondVaultFactory(admin, address(impl));
        console2.log("BondVaultFactory  :", address(factory));

        // 5. Marketplace
        BondaryMarketplace marketplace = new BondaryMarketplace(
            admin,
            address(wl),
            address(fc),
            address(factory),
            TRADING_FEE_BPS,
            EARLY_EXIT_PENALTY
        );
        console2.log("BondaryMarketplace:", address(marketplace));

        // 6. Whitelist le marketplace (il reçoit des security tokens lors des trades)
        //    Note : l'admin doit avoir le KYC_OPERATOR_ROLE (c'est le cas dans le constructeur)
        //    Ici on whiteliste depuis le deployer — en production, le Gnosis Safe le fera
        wl.whitelist(address(marketplace));
        console2.log("Marketplace whitelisted dans BondaryWhitelist");

        vm.stopBroadcast();

        _logDeploymentSummary(
            admin, asset, address(wl), address(fc), address(impl), address(factory), address(marketplace)
        );
    }

    function _logDeploymentSummary(
        address admin,
        address asset,
        address wl,
        address fc,
        address impl,
        address factory,
        address marketplace
    ) internal pure {
        console2.log("\n=== BONDARY DEPLOYMENT SUMMARY ===");
        console2.log("Admin (Gnosis Safe)  :", admin);
        console2.log("Asset token          :", asset);
        console2.log("BondaryWhitelist     :", wl);
        console2.log("BondaryFeeCollector  :", fc);
        console2.log("BondVault impl       :", impl);
        console2.log("BondVaultFactory     :", factory);
        console2.log("BondaryMarketplace   :", marketplace);
        console2.log("==================================\n");
        console2.log("NEXT STEPS:");
        console2.log("1. Transfer KYC_OPERATOR_ROLE to your KYC backend wallet");
        console2.log("2. Transfer VAULT_CREATOR_ROLE to your ops wallet (or Gnosis Safe)");
        console2.log("3. Connect KYC provider (Fractal/Synaps) to KYC operator wallet");
        console2.log("4. For each new bond: call factory.createVault(asset, name, symbol, params, admin)");
    }
}
