// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IYakFeeCollectorV1 {
    function sweepTokens(address tokenAddress, uint256 tokenAmount) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}
