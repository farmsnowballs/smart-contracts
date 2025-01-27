// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface INFTPool {
    function exists(uint256 tokenId) external view returns (bool);

    function hasDeposits() external view returns (bool);

    function lastTokenId() external view returns (uint256);

    function getPoolInfo()
        external
        view
        returns (
            address lpToken,
            address grailToken,
            address sbtToken,
            uint256 lastRewardTime,
            uint256 accRewardsPerShare,
            uint256 lpSupply,
            uint256 lpSupplyWithMultiplier,
            uint256 allocPoint
        );

    function getStakingPosition(uint256 tokenId)
        external
        view
        returns (
            uint256 amount,
            uint256 amountWithMultiplier,
            uint256 startLockTime,
            uint256 lockDuration,
            uint256 lockMultiplier,
            uint256 rewardDebt,
            uint256 boostPoints,
            uint256 totalMultiplier
        );

    function createPosition(uint256 amount, uint256 lockDuration) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function addToPosition(uint256 tokenId, uint256 amountToAdd) external;

    function getApproved(uint256 tokenId) external returns (address);

    function withdrawFromPosition(uint256 tokenId, uint256 amountToWithdraw) external;

    function emergencyWithdraw(uint256 tokenId) external;

    function pendingRewards(uint256 tokenId) external view returns (uint256);

    function harvestPosition(uint256 tokenId) external;

    function boost(uint256 userAddress, uint256 amount) external;

    function unboost(uint256 userAddress, uint256 amount) external;

    function yieldBooster() external view returns (address);

    function master() external view returns (address);

    function xGrailRewardsShare() external view returns (uint256);
}
