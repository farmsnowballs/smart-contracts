// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IPool {
    function get_balances() external view returns (uint256[] memory);
    function coins(uint256 _index) external view returns (address);
    function add_liquidity(uint256[] memory _amounts, uint256 _minAmountOut) external returns (uint256);
    function add_liquidity(uint256[2] memory _amounts, uint256 _minAmountOut) external returns (uint256);
    function add_liquidity(uint256[3] memory _amounts, uint256 _minAmountOut) external returns (uint256);
    function add_liquidity(uint256[4] memory _amounts, uint256 _minAmountOut) external returns (uint256);
}
