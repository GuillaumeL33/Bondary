// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CorporateBond} from "./CorporateBond.sol";
import {ComplianceManager} from "./ComplianceManager.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";

/**
 * @title BondFactory
 * @notice Déploie des proxies ERC1967 pointant vers l'implémentation CorporateBond.
 *         Tient un registre des bonds officiels utilisé par le Marketplace.
 *
 *         Rôles :
 *           DEFAULT_ADMIN_ROLE : peut changer l'implémentation et gérer les rôles
 *           BOND_CREATOR_ROLE  : peut créer de nouveaux bonds (Bondary ops wallet)
 */
contract BondFactory is AccessControl {
    bytes32 public constant BOND_CREATOR_ROLE = keccak256("BOND_CREATOR_ROLE");

    address public implementation;

    ComplianceManager   public immutable compliance;
    BondaryFeeCollector public immutable feeCollector;

    mapping(address => bool) private _officialBonds;
    address[] private _allBonds;

    event BondCreated(
        address indexed bond,
        address indexed issuer,
        string  name,
        string  symbol
    );
    event ImplementationUpgraded(address indexed oldImpl, address indexed newImpl);

    constructor(
        address admin,
        address _implementation,
        address _compliance,
        address _feeCollector
    ) {
        require(admin           != address(0), "BondFactory: zero admin");
        require(_implementation != address(0), "BondFactory: zero impl");
        require(_implementation.code.length > 0, "BondFactory: impl not contract");
        require(_compliance     != address(0), "BondFactory: zero compliance");
        require(_feeCollector   != address(0), "BondFactory: zero feeCollector");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BOND_CREATOR_ROLE,  admin);

        implementation = _implementation;
        compliance     = ComplianceManager(_compliance);
        feeCollector   = BondaryFeeCollector(_feeCollector);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Factory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Déploie un nouveau CorporateBond via un proxy ERC1967.
     * @param name                 Nom ERC-20 du bond token
     * @param symbol               Symbole ERC-20 du bond token
     * @param bondTerms            Paramètres économiques de l'obligation
     * @param setupFeeBps          Frais de dossier en BPS (ex: 100 = 1%)
     * @param platformCouponFeeBps Frais plateforme sur coupons en BPS
     * @param bondAdmin            Admin du bond (reçoit ADMIN_ROLE + DEFAULT_ADMIN_ROLE)
     * @return bondProxy           Adresse du proxy déployé
     */
    function createBond(
        string memory name,
        string memory symbol,
        CorporateBond.BondTerms calldata bondTerms,
        uint256 setupFeeBps,
        uint256 platformCouponFeeBps,
        address bondAdmin
    ) external onlyRole(BOND_CREATOR_ROLE) returns (address bondProxy) {
        require(bondAdmin != address(0), "BondFactory: zero bondAdmin");
        require(bondTerms.issuer != address(0), "BondFactory: zero issuer");
        bytes memory initData = abi.encodeCall(
            CorporateBond.initialize,
            (
                name,
                symbol,
                bondTerms,
                setupFeeBps,
                platformCouponFeeBps,
                address(compliance),
                address(feeCollector),
                bondAdmin
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        bondProxy = address(proxy);

        _officialBonds[bondProxy] = true;
        _allBonds.push(bondProxy);

        // Grant AUTHORIZED_SOURCE_ROLE so the bond can call feeCollector.notifyFeeReceived()
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), bondProxy);

        emit BondCreated(bondProxy, bondTerms.issuer, name, symbol);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Met à jour l'implémentation utilisée pour les futurs bonds.
     *         N'affecte PAS les proxies déjà déployés (chacun a son propre upgrade path).
     */
    function upgradeImplementation(address newImpl)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newImpl != address(0), "BondFactory: zero address");
        require(newImpl.code.length > 0, "BondFactory: impl not contract");
        address old = implementation;
        implementation = newImpl;
        emit ImplementationUpgraded(old, newImpl);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────────

    function isOfficialBond(address bond) external view returns (bool) {
        return _officialBonds[bond];
    }

    function allBonds() external view returns (address[] memory) {
        return _allBonds;
    }

    function bondCount() external view returns (uint256) {
        return _allBonds.length;
    }
}
