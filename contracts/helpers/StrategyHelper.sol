// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IStrategy {
    function checkReward() external view returns (uint256);

    function totalDeposits() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function REINVEST_REWARD_BIPS() external view returns (uint256);
}

contract StrategyHelper {
    struct StrategyInfo {
        uint256 totalSupply;
        uint256 totalDeposits;
        uint256 reward;
        uint256 reinvestRewardBips;
    }

    constructor() {}

    function strategyInfo(address strategyAddress) public view returns (StrategyInfo memory) {
        IStrategy strategy = IStrategy(strategyAddress);
        StrategyInfo memory info;
        info.totalSupply = strategy.totalSupply();
        info.totalDeposits = strategy.totalDeposits();
        info.reward = strategy.checkReward();
        info.reinvestRewardBips = strategy.REINVEST_REWARD_BIPS();
        return info;
    }
}
