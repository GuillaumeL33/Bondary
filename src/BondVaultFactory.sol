// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondVault} from "./BondVault.sol";

/**
 * @title BondVaultFactory
 * @notice Déploie un nouveau proxy BondVault (UUPS ERC1967) pour chaque obligation.
 *         Tient le registre de tous les vaults officiels Bondary.
 *
 *         Workflow :
 *           1. Bondary déploie l'implémentation BondVault (logique)
 *           2. Bondary déploie cette Factory avec l'adresse de l'implémentation
 *           3. Pour chaque nouvelle obligation, Bondary appelle createVault()
 *           4. La Factory crée un proxy ERC1967 pointant vers l'implémentation
 *           5. Chaque vault est indépendant (paramètres, emprunteur, asset propres)
 *
 *         Upgrade de l'implémentation :
 *           - setImplementation() met à jour l'adresse de référence
 *           - Les vaults existants doivent être upgradés individuellement
 *             (appel à upgradeToAndCall sur chaque proxy par le DEFAULT_ADMIN_ROLE)
 *           - Les nouveaux vaults utilisent automatiquement la nouvelle implémentation
 */
contract BondVaultFactory is AccessControl {
    bytes32 public constant VAULT_CREATOR_ROLE = keccak256("VAULT_CREATOR_ROLE");

    address public implementation;

    address[] private _vaults;
    mapping(address => bool) public isOfficialVault;

    event VaultCreated(
        address indexed vault,
        address indexed borrower,
        address indexed asset,
        uint256 vaultIndex
    );
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    constructor(address admin, address _implementation) {
        require(_implementation != address(0), "Factory: zero implementation");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VAULT_CREATOR_ROLE, admin);
        implementation = _implementation;
    }

    /**
     * @notice Déploie un nouveau vault pour une obligation donnée.
     * @param asset       Token sous-jacent (EURC ou USDC)
     * @param name        Nom ERC-20 du token de part (ex: "Bondary – PME Tech 2027")
     * @param symbol      Symbole ERC-20 (ex: "BND-PME27")
     * @param params      Paramètres du vault (taux, durée, caps, adresses…)
     * @param vaultAdmin  Adresse admin du vault (généralement le Gnosis Safe Bondary)
     * @return vault      Adresse du proxy déployé
     */
    function createVault(
        address asset,
        string calldata name,
        string calldata symbol,
        BondVault.VaultParams calldata params,
        address vaultAdmin
    ) external onlyRole(VAULT_CREATOR_ROLE) returns (address vault) {
        require(asset != address(0),      "Factory: zero asset");
        require(vaultAdmin != address(0), "Factory: zero admin");

        bytes memory initData = abi.encodeCall(
            BondVault.initialize,
            (IERC20(asset), name, symbol, params, vaultAdmin)
        );

        vault = address(new ERC1967Proxy(implementation, initData));

        _vaults.push(vault);
        isOfficialVault[vault] = true;

        emit VaultCreated(vault, params.borrower, asset, _vaults.length - 1);
    }

    /**
     * @notice Met à jour l'adresse de l'implémentation pour les futurs vaults.
     *         N'affecte pas les vaults déjà déployés.
     */
    function setImplementation(address newImpl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImpl != address(0), "Factory: zero address");
        emit ImplementationUpdated(implementation, newImpl);
        implementation = newImpl;
    }

    function getVaults() external view returns (address[] memory) {
        return _vaults;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }
}
