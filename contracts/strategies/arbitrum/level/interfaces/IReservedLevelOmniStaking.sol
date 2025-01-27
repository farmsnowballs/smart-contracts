// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IReservedLevelOmniStaking {
    struct UserInfo {
        /// @notice staked amount of user in epoch
        uint256 amount;
        uint256 claimedReward;
        /// @notice accumulated amount, calculated by total of deposited amount multiplied with deposited time
        uint256 accShare;
        uint256 lastUpdateAccShareTime;
    }

    function currentEpoch() external view returns (uint256);

    function pendingRewards(uint256 _epoch, address _user) external view returns (uint256 _pendingRewards);

    function stake(address _to, uint256 _amount) external;

    function unstake(address _to, uint256 _amount) external;

    function stakedAmounts(address _user) external view returns (uint256);

    function claimRewards(uint256 _epoch, address _to) external;

    function claimRewardsToSingleToken(uint256 _epoch, address _to, address _tokenOut, uint256 _minAmountOut)
        external;

    function STAKING_TAX_PRECISION() external view returns (uint256);

    function STAKING_TAX() external view returns (uint256);

    function claimableTokens(address _token) external view returns (bool);

    function LLP() external view returns (address);
}
