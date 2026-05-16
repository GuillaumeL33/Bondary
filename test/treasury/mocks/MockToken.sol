// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 with configurable decimals and unrestricted mint.
///      Used only in `test/treasury/`. Not deployed to mainnet.
contract MockToken is ERC20 {
    uint8 private immutable _customDecimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _customDecimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
