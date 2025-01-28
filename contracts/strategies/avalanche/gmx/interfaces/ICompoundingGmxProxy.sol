// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./IGmxDepositor.sol";

interface ICompoundingGmxProxy {
    function gmxDepositor() external view returns (IGmxDepositor);

    function gmxRewardRouter() external view returns (address);

    function stake(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function pendingRewards() external view returns (uint256);

    function claimReward() external;

    function totalDeposits() external view returns (uint256);

    function emergencyWithdraw(uint256 _balance) external;
}
