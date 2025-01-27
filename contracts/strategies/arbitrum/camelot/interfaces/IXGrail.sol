// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IXGrail {
    function convert(uint256 amount) external;

    function xGrailBalances(address account) external view returns (uint256, uint256);

    function approveUsage(address usage, uint256 amount) external;

    function allocate(
        address usageAddress,
        uint256 amount,
        bytes calldata data
    ) external;

    function deallocate(
        address usageAddress,
        uint256 amount,
        bytes calldata data
    ) external;

    function balanceOf(address account) external view returns (uint256);
}
