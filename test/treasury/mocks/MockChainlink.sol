// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract MockChainlink {
    int256 internal _answer;
    uint8 internal _decimals;
    uint256 internal _updatedAt;

    constructor(int256 ans, uint8 dec, uint256 ts) {
        _answer = ans;
        _decimals = dec;
        _updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setAnswer(int256 a) external { _answer = a; }
    function setUpdatedAt(uint256 t) external { _updatedAt = t; }
}
