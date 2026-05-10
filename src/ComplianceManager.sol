// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICompliance, IIdentity, IIdentityRegistry} from "./interfaces/IERC3643.sol";

/**
 * @title ComplianceManager
 * @notice ERC-3643-compatible identity registry and compliance module.
 *
 * --- Audit H1 fixes (mai 2026) -----------------------------------------------
 *  S-05  bindToken() restricted to COMPLIANCE_ADMIN_ROLE. The msg.sender ==
 *        token shortcut is removed: any contract could otherwise self-bind
 *        and emit misleading TokenBound events. BondFactory receives
 *        COMPLIANCE_ADMIN_ROLE and binds each bond proxy after deployment.
 *
 *  S-06  _registerIdentity() validates IIdentity when it differs from the
 *        wallet. A real ONCHAINID must declare a MANAGEMENT key (purpose 1)
 *        for the investor wallet. Simplified mode (whitelist legacy where
 *        identity == wallet) keeps its prior behavior.
 * ----------------------------------------------------------------------------
 */
contract ComplianceManager is AccessControl, IIdentityRegistry, ICompliance {
    bytes32 public constant KYC_OPERATOR_ROLE = keccak256("KYC_OPERATOR_ROLE");
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");

    /// @dev ERC-734 purpose 1 = MANAGEMENT (per ONCHAINID convention).
    uint256 internal constant ONCHAINID_MANAGEMENT_PURPOSE = 1;

    struct InvestorIdentity {
        IIdentity identity;
        uint16 country;
        bool registered;
    }

    mapping(address => InvestorIdentity) private _identities;
    mapping(address => bool) private _blacklisted;
    mapping(address => bool) private _boundTokens;

    event Whitelisted(address indexed account);
    event WhitelistRevoked(address indexed account);
    event Blacklisted(address indexed account, string reason);
    event Unblacklisted(address indexed account);

    constructor(address admin) {
        require(admin != address(0), "Compliance: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_OPERATOR_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
    }

    // ------- Legacy Bondary KYC helpers --------------------------------------

    /// @notice Simplified mode: registers `account` with itself as IIdentity.
    ///         No claim validation. Suitable for testnet / flat operator
    ///         whitelists. Production deployments should use registerIdentity()
    ///         with a real ONCHAINID contract.
    function whitelist(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _registerIdentity(account, IIdentity(account), 0);
        emit Whitelisted(account);
    }

    function revoke(address account) external onlyRole(KYC_OPERATOR_ROLE) {
        _deleteIdentity(account);
        emit WhitelistRevoked(account);
    }

    function batchWhitelist(address[] calldata accounts) external onlyRole(KYC_OPERATOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            _registerIdentity(accounts[i], IIdentity(accounts[i]), 0);
            emit Whitelisted(accounts[i]);
        }
    }

    function blacklist(address account, string calldata reason)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        _blacklisted[account] = true;
        emit Blacklisted(account, reason);
    }

    function unblacklist(address account) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ------- ERC-3643 Identity Registry --------------------------------------

    function registerIdentity(address userAddress, IIdentity userIdentity, uint16 country)
        external
        onlyRole(KYC_OPERATOR_ROLE)
    {
        _registerIdentity(userAddress, userIdentity, country);
    }

    function deleteIdentity(address userAddress) external onlyRole(KYC_OPERATOR_ROLE) {
        _deleteIdentity(userAddress);
    }

    function updateCountry(address userAddress, uint16 country) external onlyRole(KYC_OPERATOR_ROLE) {
        require(_identities[userAddress].registered, "Compliance: identity missing");
        _identities[userAddress].country = country;
        emit CountryUpdated(userAddress, country);
    }

    function updateIdentity(address userAddress, IIdentity userIdentity)
        external
        onlyRole(KYC_OPERATOR_ROLE)
    {
        require(address(userIdentity) != address(0), "Compliance: zero identity");
        require(_identities[userAddress].registered, "Compliance: identity missing");
        _validateIdentity(userAddress, userIdentity);
        IIdentity oldIdentity = _identities[userAddress].identity;
        _identities[userAddress].identity = userIdentity;
        emit IdentityUpdated(oldIdentity, userIdentity);
    }

    function batchRegisterIdentity(
        address[] calldata userAddresses,
        IIdentity[] calldata identities,
        uint16[] calldata countries
    ) external onlyRole(KYC_OPERATOR_ROLE) {
        require(
            userAddresses.length == identities.length && userAddresses.length == countries.length,
            "Compliance: length mismatch"
        );
        for (uint256 i = 0; i < userAddresses.length; i++) {
            _registerIdentity(userAddresses[i], identities[i], countries[i]);
        }
    }

    function contains(address userAddress) external view returns (bool) {
        return _identities[userAddress].registered;
    }

    function isVerified(address userAddress) public view returns (bool) {
        InvestorIdentity memory investor = _identities[userAddress];
        return investor.registered && address(investor.identity) != address(0) && !_blacklisted[userAddress];
    }

    function identity(address userAddress) external view returns (IIdentity) {
        return _identities[userAddress].identity;
    }

    function investorCountry(address userAddress) external view returns (uint16) {
        return _identities[userAddress].country;
    }

    function isWhitelisted(address account) external view returns (bool) {
        return _identities[account].registered;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    // ------- ERC-3643 Compliance ---------------------------------------------

    /// @notice S-05 : restricted to COMPLIANCE_ADMIN_ROLE. BondFactory receives
    ///         this role in the deploy script and binds each new bond proxy.
    function bindToken(address token) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        require(token != address(0), "Compliance: zero token");
        if (!_boundTokens[token]) {
            _boundTokens[token] = true;
            emit TokenBound(token);
        }
    }

    function unbindToken(address token) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        require(_boundTokens[token], "Compliance: token not bound");
        _boundTokens[token] = false;
        emit TokenUnbound(token);
    }

    function isTokenBound(address token) external view returns (bool) {
        return _boundTokens[token];
    }

    function canTransfer(address from, address to, uint256) external view returns (bool) {
        if (to == address(0)) return true;
        if (from == address(0)) return isVerified(to);
        return isVerified(from) && isVerified(to);
    }

    function transferred(address, address, uint256) external view onlyBoundToken {}
    function created(address, uint256) external view onlyBoundToken {}
    function destroyed(address, uint256) external view onlyBoundToken {}

    modifier onlyBoundToken() {
        require(_boundTokens[msg.sender], "Compliance: caller not bound token");
        _;
    }

    function _registerIdentity(address userAddress, IIdentity userIdentity, uint16 country) internal {
        require(userAddress != address(0), "Compliance: zero user");
        require(address(userIdentity) != address(0), "Compliance: zero identity");

        // S-06 : validate the IIdentity when it is a separate contract.
        _validateIdentity(userAddress, userIdentity);

        IIdentity oldIdentity = _identities[userAddress].identity;
        bool wasRegistered = _identities[userAddress].registered;

        _identities[userAddress] = InvestorIdentity({
            identity: userIdentity,
            country: country,
            registered: true
        });

        if (wasRegistered) {
            emit IdentityUpdated(oldIdentity, userIdentity);
            emit CountryUpdated(userAddress, country);
        } else {
            emit IdentityRegistered(userAddress, userIdentity);
        }
    }

    function _deleteIdentity(address userAddress) internal {
        InvestorIdentity memory investor = _identities[userAddress];
        require(investor.registered, "Compliance: identity missing");
        delete _identities[userAddress];
        emit IdentityRemoved(userAddress, investor.identity);
    }

    /// @dev S-06 : when identity != wallet, require the identity contract to
    ///      declare a management key (purpose 1) for the wallet. Simplified
    ///      mode (identity == wallet) is skipped because EOAs do not
    ///      implement keyHasPurpose.
    function _validateIdentity(address userAddress, IIdentity userIdentity) internal view {
        if (address(userIdentity) == userAddress) return;
        bytes32 walletKey = keccak256(abi.encode(userAddress));
        try userIdentity.keyHasPurpose(walletKey, ONCHAINID_MANAGEMENT_PURPOSE) returns (bool ok) {
            require(ok, "Compliance: identity missing management key");
        } catch {
            revert("Compliance: invalid identity contract");
        }
    }
}
