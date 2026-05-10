// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice ERC-20 6-decimal clone for Sepolia testing. Public mint with cap.
 *         **DO NOT DEPLOY ON MAINNET.** On mainnet use the real Circle USDC.
 */
contract MockUSDC is ERC20 {
    /// @notice Per-call mint cap (anti-spam).
    uint256 public constant MAX_MINT_PER_CALL = 1_000_000 * 10**6; // 1M USDC

    /// @notice Amount delivered by faucet().
    uint256 public constant FAUCET_AMOUNT = 10_000 * 10**6;        // 10k USDC

    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Public capped mint. For automated tests.
    function mint(address to, uint256 amount) external {
        require(amount <= MAX_MINT_PER_CALL, "MockUSDC: exceeds mint cap");
        _mint(to, amount);
    }

    /// @notice Faucet — mints 10,000 USDC to msg.sender.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
