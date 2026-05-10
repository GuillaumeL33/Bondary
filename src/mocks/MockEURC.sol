// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockEURC
 * @notice ERC-20 6-decimal clone for Sepolia testing. Public mint with cap.
 *         **DO NOT DEPLOY ON MAINNET.** On mainnet use the real Circle EURC.
 */
contract MockEURC is ERC20 {
    uint256 public constant MAX_MINT_PER_CALL = 1_000_000 * 10**6; // 1M EURC
    uint256 public constant FAUCET_AMOUNT     = 10_000 * 10**6;    // 10k EURC

    constructor() ERC20("Mock Euro Coin", "EURC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(amount <= MAX_MINT_PER_CALL, "MockEURC: exceeds mint cap");
        _mint(to, amount);
    }

    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
