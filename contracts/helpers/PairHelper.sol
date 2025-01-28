// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IPair.sol";
import "./interfaces/IOracleVault.sol";

contract PairHelper {
    struct PairInfo {
        string symbol;
        uint256 totalSupply;
        uint8 decimals;
        address token0;
        address token1;
        string token0Symbol;
        string token1Symbol;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 reserve0;
        uint256 reserve1;
    }

    constructor() {}

    function pairInfo(address pairAddress) public view returns (PairInfo memory) {
        IPair pair = IPair(pairAddress);
        PairInfo memory info;
        info.symbol = pair.symbol();
        info.totalSupply = pair.totalSupply();
        info.decimals = pair.decimals();
        info.token0 = pair.token0();
        info.token1 = pair.token1();

        info.token0Symbol = IPair(info.token0).symbol();
        info.token1Symbol = IPair(info.token1).symbol();

        info.token0Decimals = IPair(info.token0).decimals();
        info.token1Decimals = IPair(info.token1).decimals();

        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        info.reserve0 = reserve0;
        info.reserve1 = reserve1;
        return info;
    }

    function oracleVaultInfo(address pairAddress) public view returns (PairInfo memory) {
        IOracleVault pair = IOracleVault(pairAddress);
        PairInfo memory info;
        info.symbol = pair.symbol();
        info.totalSupply = pair.totalSupply();
        info.decimals = pair.decimals();
        info.token0 = pair.getTokenX();
        info.token1 = pair.getTokenY();

        info.token0Symbol = IPair(info.token0).symbol();
        info.token1Symbol = IPair(info.token1).symbol();

        info.token0Decimals = IPair(info.token0).decimals();
        info.token1Decimals = IPair(info.token1).decimals();

        (uint256 amountX, uint256 amountY) = pair.getBalances();
        info.reserve0 = amountX;
        info.reserve1 = amountY;
        return info;
    }
}
