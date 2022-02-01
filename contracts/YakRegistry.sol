// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;
pragma experimental ABIEncoderV2;

import "./lib/Ownable.sol";
import "./lib/EnumerableSet.sol";
import "./YakStrategy.sol";

/**
 * @notice YakRegistry is a list of officially supported strategies.
 */
contract YakRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => uint256) public strategyIdForStrategyAddress;
    mapping(address => uint256[]) public strategyIdsForDepositToken;
    mapping(address => bool) public pausedStrategies;
    mapping(address => bool) public disabledStrategies;
    EnumerableSet.AddressSet private strategies;

    struct StrategyInfo {
        uint256 id;
        address strategyAddress;
        bool depositsEnabled;
        address depositToken;
        address rewardToken;
        uint256 minTokensToReinvest;
        uint256 maxTokensToDepositWithoutReinvest;
        uint256 adminFeeBips;
        uint256 devFeeBips;
        uint256 reinvestRewardBips;
    }

    event AddStrategy(address indexed strategy);

    constructor() {}

    function isActiveStrategy(address _strategy) external view returns (bool) {
        YakStrategy strategy = YakStrategy(_strategy);
        return
            strategies.contains(_strategy) &&
            strategy.DEPOSITS_ENABLED() &&
            !pausedStrategies[_strategy] &&
            !disabledStrategies[_strategy];
    }

    function isHaltedStrategy(address _strategy) external view returns (bool) {
        return !pausedStrategies[_strategy] && !disabledStrategies[_strategy];
    }

    function strategiesForDepositTokenCount(address _depositToken) external view returns (uint256) {
        return strategyIdsForDepositToken[_depositToken].length;
    }

    function strategyInfo(uint256 _sId) external view returns (StrategyInfo memory) {
        address strategyAddress = strategies.at(_sId);
        YakStrategy strategy = YakStrategy(strategyAddress);
        return
            StrategyInfo({
                id: _sId,
                strategyAddress: address(strategy),
                depositsEnabled: strategy.DEPOSITS_ENABLED(),
                depositToken: address(strategy.depositToken()),
                rewardToken: address(strategy.rewardToken()),
                minTokensToReinvest: strategy.MIN_TOKENS_TO_REINVEST(),
                maxTokensToDepositWithoutReinvest: strategy.MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST(),
                adminFeeBips: strategy.ADMIN_FEE_BIPS(),
                devFeeBips: strategy.DEV_FEE_BIPS(),
                reinvestRewardBips: strategy.REINVEST_REWARD_BIPS()
            });
    }

    function strategyId(address _strategy) external view returns (uint256) {
        return strategyIdForStrategyAddress[_strategy];
    }

    function strategiesCount() external view returns (uint256) {
        return strategies.length();
    }

    /**
     * @notice Add a new YakStrategy
     * @dev Calls strategyInfo() to verify the new strategy implements required interface
     * @param _strategy address for new strategy
     * @return StrategyInfo of added strategy
     */
    function addStrategy(address _strategy) external onlyOwner returns (StrategyInfo memory) {
        require(strategies.add(_strategy), "YakRegistry::addStrategy, strategy already added");
        uint256 id = strategies.length() - 1;
        address depositToken = address(YakStrategy(_strategy).depositToken());
        strategyIdsForDepositToken[depositToken].push(id);
        strategyIdForStrategyAddress[_strategy] = id;
        StrategyInfo memory info = this.strategyInfo(id);
        emit AddStrategy(_strategy);
        return info;
    }

    function pauseStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = true;
    }

    function disableStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = false;
        disabledStrategies[_strategy] = true;
    }

    function resumeStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = false;
        disabledStrategies[_strategy] = false;
    }
}
