// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IStableJoeStaking {
    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function emergencyWithdraw() external;

    function pendingReward(address _user, address _token) external view returns (uint256);

    function rewardTokens(uint256 index) external view returns (address);

    function rewardTokensLength() external view returns (uint256);

    function getUserInfo(address _user, address _rewardToken) external view returns (uint256, uint256);

    function depositFeePercent() external view returns (uint256);

    function DEPOSIT_FEE_PERCENT_PRECISION() external view returns (uint256);
}
