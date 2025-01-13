// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IGauge {
    function deposit(uint256 amount, uint256 tokenId) external;
    function withdraw(uint256 amount) external;
    function withdrawAll() external;
    function earned(address token, address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getReward(address account, address[] memory tokens) external;
}
