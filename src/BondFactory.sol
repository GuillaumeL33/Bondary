// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CorporateBond} from "./CorporateBond.sol";
import {ComplianceManager} from "./ComplianceManager.sol";
import {BondaryFeeCollector} from "./BondaryFeeCollector.sol";

/**
 * @title BondFactory
 * @notice Deploys ERC1967 proxies pointing to the CorporateBond implementation.
 *         Maintains a registry of official bonds used by the marketplace.
 *
 * --- Audit fixes -------------------------------------------------------------
 *   H-02  upgradeImplementation() in two steps with timelock
 *   S-04  UPGRADE_DELAY 48h -> 7 days (aligned with CorporateBond)
 *   S-05  createBond() calls compliance.bindToken() after deployment
 *   S-08  allBonds(offset, limit) paginated to avoid gas DoS
 * ----------------------------------------------------------------------------
 */
contract BondFactory is AccessControl {
    bytes32 public constant BOND_CREATOR_ROLE = keccak256("BOND_CREATOR_ROLE");

    /// @notice S-04 : aligned on CorporateBond.UPGRADE_DELAY (industry standard 7-14d).
    uint256 public constant UPGRADE_DELAY = 7 days;

    address public implementation;

    address public pendingImplementation;
    uint256 public pendingImplementationTimestamp;

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
    event ImplementationProposed(address indexed newImpl, uint256 executableAt);
    event ImplementationUpgradeCancelled(address indexed impl);

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

    // ------- Factory ---------------------------------------------------------

    /// @notice Deploys a new CorporateBond via an ERC1967 proxy.
    ///         Requires:
    ///           * COMPLIANCE_ADMIN_ROLE on ComplianceManager (binds new bonds)
    ///           * DEFAULT_ADMIN_ROLE on BondaryFeeCollector (auto-grants AUTHORIZED_SOURCE_ROLE)
    ///         Both roles are granted to this factory in Deploy.s.sol.
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

        // S-05 : bind the new bond on ComplianceManager.
        compliance.bindToken(bondProxy);

        // Grant AUTHORIZED_SOURCE_ROLE so the bond can call feeCollector.notifyFeeReceived().
        feeCollector.grantRole(feeCollector.AUTHORIZED_SOURCE_ROLE(), bondProxy);

        emit BondCreated(bondProxy, bondTerms.issuer, name, symbol);
    }

    // ------- Implementation upgrade (two-step + 7d timelock) -----------------

    function proposeImplementation(address newImpl)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(pendingImplementation == address(0), "BondFactory: upgrade already pending");
        require(newImpl != address(0),               "BondFactory: zero address");
        require(newImpl.code.length > 0,             "BondFactory: impl not contract");
        pendingImplementation = newImpl;
        pendingImplementationTimestamp = block.timestamp + UPGRADE_DELAY;
        emit ImplementationProposed(newImpl, pendingImplementationTimestamp);
    }

    function executeImplementationUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(pendingImplementation != address(0),              "BondFactory: no upgrade pending");
        require(block.timestamp >= pendingImplementationTimestamp, "BondFactory: upgrade timelocked");
        address old = implementation;
        implementation = pendingImplementation;
        pendingImplementation = address(0);
        pendingImplementationTimestamp = 0;
        emit ImplementationUpgraded(old, implementation);
    }

    function cancelImplementationUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address cancelled = pendingImplementation;
        require(cancelled != address(0), "BondFactory: no upgrade pending");
        pendingImplementation = address(0);
        pendingImplementationTimestamp = 0;
        emit ImplementationUpgradeCancelled(cancelled);
    }

    // ------- Views -----------------------------------------------------------

    function isOfficialBond(address bond) external view returns (bool) {
        return _officialBonds[bond];
    }

    /// @notice Legacy: returns all bonds. Use allBondsPaged() once the list grows.
    function allBonds() external view returns (address[] memory) {
        return _allBonds;
    }

    /// @notice S-08 : paginated read of the bond list.
    function allBondsPaged(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total)
    {
        total = _allBonds.length;
        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        page = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = _allBonds[offset + i];
        }
    }

    function bondCount() external view returns (uint256) {
        return _allBonds.length;
    }
}
