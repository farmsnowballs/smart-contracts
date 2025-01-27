// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ILevelPool {
    function addLiquidity(address tranche, address assetToken, uint256 assetAmount, uint256 minLpAmount, address to)
        external;

    function liquidityCalculator() external view returns (address);

    function oracle() external view returns (address);

    function getAllAssets() external view returns (address[] memory, bool[] memory);
}
