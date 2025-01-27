// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface INitroPool {
    struct Settings {
        uint256 startTime; // Start of rewards distribution
        uint256 endTime; // End of rewards distribution
        uint256 harvestStartTime; // (optional) Time at which stakers will be allowed to harvest their rewards
        uint256 depositEndTime; // (optional) Time at which deposits won't be allowed anymore
        uint256 lockDurationReq; // (optional) required lock duration for positions
        uint256 lockEndReq; // (optional) required lock end time for positions
        uint256 depositAmountReq; // (optional) required deposit amount for positions
        bool whitelist; // (optional) to only allow whitelisted users to deposit
        string description; // Project's description for this NitroPool
    }

    function withdraw(uint256 positionId) external;

    function pendingRewards(address account) external view returns (uint256 pending1, uint256 pending2);

    function rewardsToken1() external view returns (address);

    function rewardsToken2() external view returns (address);

    function harvest() external;

    function nftPool() external view returns (address);

    function settings()
        external
        view
        returns (
            uint256 startTime, // Start of rewards distribution
            uint256 endTime, // End of rewards distribution
            uint256 harvestStartTime, // (optional) Time at which stakers will be allowed to harvest their rewards
            uint256 depositEndTime, // (optional) Time at which deposits won't be allowed anymore
            uint256 lockDurationReq, // (optional) required lock duration for positions
            uint256 lockEndReq, // (optional) required lock end time for positions
            uint256 depositAmountReq, // (optional) required deposit amount for positions
            bool whitelist, // (optional) to only allow whitelisted users to deposit
            string memory description
        );
}
