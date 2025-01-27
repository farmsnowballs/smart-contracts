// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ILevelOracle {
    function getPrice(address token, bool max) external view returns (uint256);
}
