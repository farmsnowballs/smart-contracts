// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IOracleVault {
    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);

    function getTokenX() external view returns (address);

    function getTokenY() external view returns (address);

    function getBalances()
        external
        view
        returns (
            uint256 amountX,
            uint256 amountY
        );
}