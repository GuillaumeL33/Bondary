// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBrivoVault} from "./interfaces/IBrivoVault.sol";
import {IProductEligibilityRegistry} from "./interfaces/IProductEligibilityRegistry.sol";
import {ITreasuryFeeCollector} from "./interfaces/ITreasuryFeeCollector.sol";
import {TreasuryErrors} from "./libraries/TreasuryErrors.sol";
import {TreasuryRoles} from "./libraries/TreasuryRoles.sol";

/// @title BrivoVault — 1:1 wrap of a non-rebasing underlying (e.g. USDY).
/// @notice Mints and burns are restricted to gateway contracts holding
///         `VAULT_GATEWAY_ROLE` (the SubscriptionQueue / RedemptionQueue).
///         Direct user deposit/redeem is not supported in V1.
/// @dev    Non-upgradeable. To migrate, deploy a new vault and use the
///         RescueManager `MigrateUnderlying` proposal kind.
contract BrivoVault is ERC20Pausable, AccessControl, ReentrancyGuard, IBrivoVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    bytes32 public immutable productId;
    IProductEligibilityRegistry public immutable eligibility;

    ITreasuryFeeCollector public feeCollector;
    uint256 public subscriptionCap;
    uint256 public minSubscription;

    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        IERC20 underlying_,
        bytes32 productId_,
        IProductEligibilityRegistry eligibility_,
        ITreasuryFeeCollector feeCollector_,
        address admin,
        uint256 subscriptionCap_,
        uint256 minSubscription_
    ) ERC20(name_, symbol_) {
        if (address(underlying_) == address(0)) revert TreasuryErrors.ZeroAddress();
        if (address(eligibility_) == address(0)) revert TreasuryErrors.ZeroAddress();
        if (admin == address(0)) revert TreasuryErrors.ZeroAddress();
        if (productId_ == bytes32(0)) revert TreasuryErrors.VaultProductMismatch();
        if (subscriptionCap_ == 0) revert TreasuryErrors.ZeroAmount();

        underlying = underlying_;
        productId = productId_;
        eligibility = eligibility_;
        feeCollector = feeCollector_;
        subscriptionCap = subscriptionCap_;
        minSubscription = minSubscription_;
        _decimals = IERC20Metadata(address(underlying_)).decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.TREASURY_ADMIN_ROLE, admin);
        _grantRole(TreasuryRoles.PAUSER_ROLE, admin);

        emit ProductIdSet(productId_);
        emit EligibilityRegistrySet(address(eligibility_));
        emit FeeCollectorSet(address(feeCollector_));
        emit SubscriptionCapSet(0, subscriptionCap_);
        emit MinSubscriptionSet(0, minSubscription_);
    }

    // ---------------- views ----------------

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalAssets() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    // ---------------- gateway-only mint / burn ----------------

    function depositFor(uint256 assets, address receiver, address caller)
        external
        onlyRole(TreasuryRoles.VAULT_GATEWAY_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert TreasuryErrors.ZeroAmount();
        if (receiver == address(0)) revert TreasuryErrors.ZeroAddress();
        if (caller == address(0)) revert TreasuryErrors.ZeroAddress();
        if (assets < minSubscription) revert TreasuryErrors.VaultBelowMinimum(assets, minSubscription);
        uint256 newSupply = totalSupply() + assets;
        if (newSupply > subscriptionCap) revert TreasuryErrors.VaultCapExceeded(newSupply, subscriptionCap);

        // Pull underlying first so that I1 (totalAssets >= totalSupply) holds
        // across the mint.
        underlying.safeTransferFrom(caller, address(this), assets);
        _mint(receiver, assets);

        emit Subscribed(caller, receiver, assets, assets);
        return assets;
    }

    function redeemFor(uint256 shares, address receiver, address owner)
        external
        onlyRole(TreasuryRoles.VAULT_GATEWAY_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert TreasuryErrors.ZeroAmount();
        if (receiver == address(0)) revert TreasuryErrors.ZeroAddress();
        // V1 simplification: the gateway must always burn its own shares.
        // ERC-4626-style allowance redemption can be added in V2.
        if (owner != msg.sender) revert TreasuryErrors.VaultOwnerMismatch(msg.sender, owner);

        _burn(owner, shares);
        underlying.safeTransfer(receiver, shares);

        emit Redeemed(msg.sender, receiver, shares, shares);
        return shares;
    }

    // ---------------- eligibility hook ----------------

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Mint or transfer: receiver must be eligible.
        if (to != address(0)) {
            (bool ok, bytes32 reason) = eligibility.checkEligibility(productId, to);
            if (!ok) revert TreasuryErrors.UserNotEligible(productId, to, reason);
        }
        // Transfer: sender must also be eligible. Burn (to == 0) is always
        // allowed so a blocklisted user can still exit through the redemption
        // queue (queue holds the shares and is itself allowlisted).
        if (from != address(0) && to != address(0)) {
            (bool ok, bytes32 reason) = eligibility.checkEligibility(productId, from);
            if (!ok) revert TreasuryErrors.UserNotEligible(productId, from, reason);
        }
        super._update(from, to, value);
    }

    // ---------------- admin ----------------

    function setSubscriptionCap(uint256 newCap)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        if (newCap == 0) revert TreasuryErrors.ZeroAmount();
        uint256 old = subscriptionCap;
        subscriptionCap = newCap;
        emit SubscriptionCapSet(old, newCap);
    }

    function setMinSubscription(uint256 newMin)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        uint256 old = minSubscription;
        minSubscription = newMin;
        emit MinSubscriptionSet(old, newMin);
    }

    function setFeeCollector(address newCollector)
        external
        onlyRole(TreasuryRoles.TREASURY_ADMIN_ROLE)
    {
        feeCollector = ITreasuryFeeCollector(newCollector);
        emit FeeCollectorSet(newCollector);
    }

    function pause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(TreasuryRoles.PAUSER_ROLE) {
        _unpause();
    }

    function reclaimExcess(address to)
        external
        onlyRole(TreasuryRoles.RESCUE_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert TreasuryErrors.ZeroAddress();
        uint256 bal = underlying.balanceOf(address(this));
        uint256 supply = totalSupply();
        if (bal <= supply) return 0;
        amount = bal - supply;
        underlying.safeTransfer(to, amount);
        emit ExcessReclaimed(to, amount);
    }
}
