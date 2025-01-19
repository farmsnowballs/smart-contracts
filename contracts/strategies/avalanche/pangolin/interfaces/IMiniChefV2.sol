// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IMiniChefV2 {
    function userInfo(uint256 pid, address user) external view returns (uint256 amount, uint256 rewardDebt);

    function poolInfo(uint256 pid)
        external
        view
        returns (uint256 allocPoint, uint256 lastRewardTime, uint256 accRewardPerShare);

    function REWARD() external view returns (address);

    function rewarder(uint256 pid) external view returns (address);

    function lpToken(uint256 pid) external view returns (address);

    function pendingReward(uint256 _pid, address _user) external view returns (uint256);

    function deposit(uint256 pid, uint256 amount, address to) external;

    function withdraw(uint256 pid, uint256 amount, address to) external;

    function harvest(uint256 pid, address to) external;

    function emergencyWithdraw(uint256 pid, address to) external;
}
