// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IIdentity {
    function keyHasPurpose(bytes32 key, uint256 purpose) external view returns (bool);
}

interface IIdentityRegistry {
    event IdentityRegistered(address indexed investorAddress, IIdentity indexed identity);
    event IdentityRemoved(address indexed investorAddress, IIdentity indexed identity);
    event IdentityUpdated(IIdentity indexed oldIdentity, IIdentity indexed newIdentity);
    event CountryUpdated(address indexed investorAddress, uint16 indexed country);

    function registerIdentity(address userAddress, IIdentity identity, uint16 country) external;
    function deleteIdentity(address userAddress) external;
    function updateCountry(address userAddress, uint16 country) external;
    function updateIdentity(address userAddress, IIdentity identity) external;
    function batchRegisterIdentity(
        address[] calldata userAddresses,
        IIdentity[] calldata identities,
        uint16[] calldata countries
    ) external;
    function contains(address userAddress) external view returns (bool);
    function isVerified(address userAddress) external view returns (bool);
    function identity(address userAddress) external view returns (IIdentity);
    function investorCountry(address userAddress) external view returns (uint16);
}

interface ICompliance {
    event TokenBound(address token);
    event TokenUnbound(address token);

    function bindToken(address token) external;
    function unbindToken(address token) external;
    function isTokenBound(address token) external view returns (bool);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
    function transferred(address from, address to, uint256 amount) external;
    function created(address to, uint256 amount) external;
    function destroyed(address from, uint256 amount) external;
}

interface IERC3643 is IERC20 {
    event UpdatedTokenInformation(
        string newName,
        string newSymbol,
        uint8 newDecimals,
        string newVersion,
        address indexed newOnchainID
    );
    event IdentityRegistryAdded(address indexed identityRegistry);
    event ComplianceAdded(address indexed compliance);
    event RecoverySuccess(
        address indexed lostWallet,
        address indexed newWallet,
        address indexed investorOnchainID
    );
    event AddressFrozen(address indexed userAddress, bool indexed isFrozen, address indexed agent);
    event TokensFrozen(address indexed userAddress, uint256 amount);
    event TokensUnfrozen(address indexed userAddress, uint256 amount);

    function setName(string calldata newName) external;
    function setSymbol(string calldata newSymbol) external;
    function setOnchainID(address newOnchainID) external;
    function pause() external;
    function unpause() external;
    function setAddressFrozen(address userAddress, bool freeze) external;
    function freezePartialTokens(address userAddress, uint256 amount) external;
    function unfreezePartialTokens(address userAddress, uint256 amount) external;
    function setIdentityRegistry(address identityRegistry) external;
    function setCompliance(address compliance) external;
    function forcedTransfer(address from, address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
    function burn(address userAddress, uint256 amount) external;
    function recoveryAddress(address lostWallet, address newWallet, address investorOnchainID)
        external
        returns (bool);
    function batchTransfer(address[] calldata toList, uint256[] calldata amounts) external;
    function batchForcedTransfer(
        address[] calldata fromList,
        address[] calldata toList,
        uint256[] calldata amounts
    ) external;
    function batchMint(address[] calldata toList, uint256[] calldata amounts) external;
    function batchBurn(address[] calldata userAddresses, uint256[] calldata amounts) external;
    function batchSetAddressFrozen(address[] calldata userAddresses, bool[] calldata freeze) external;
    function batchFreezePartialTokens(address[] calldata userAddresses, uint256[] calldata amounts)
        external;
    function batchUnfreezePartialTokens(address[] calldata userAddresses, uint256[] calldata amounts)
        external;
    function onchainID() external view returns (address);
    function version() external view returns (string memory);
    function identityRegistry() external view returns (IIdentityRegistry);
    function compliance() external view returns (ICompliance);
    function isFrozen(address userAddress) external view returns (bool);
    function getFrozenTokens(address userAddress) external view returns (uint256);
}
