// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../lamapay/LamaPayStrategyBase.sol";
import "./interfaces/IGmxRewardRouter.sol";
import "./interfaces/IGmxRewardTracker.sol";

contract BoostedGmxStrategy is LamaPayStrategyBase {
    using SafeERC20 for IERC20;

    IGmxRewardRouter public immutable gmxRewardRouter;
    IGmxRewardTracker public immutable feeGmxTracker;
    IGmxRewardTracker public immutable stakedGmxTracker;

    constructor(
        address _gmxRewardRouter,
        BaseStrategySettings memory baseStrategySettings,
        StrategySettings memory _strategySettings
    ) LamaPayStrategyBase(baseStrategySettings, _strategySettings) {
        gmxRewardRouter = IGmxRewardRouter(_gmxRewardRouter);
        feeGmxTracker = IGmxRewardTracker(gmxRewardRouter.feeGmxTracker());
        stakedGmxTracker = IGmxRewardTracker(gmxRewardRouter.stakedGmxTracker());
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(stakedGmxTracker), _amount);
        gmxRewardRouter.stakeGmx(_amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        gmxRewardRouter.unstakeGmx(_amount);
        return _amount;
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        Reward[] memory rewards = new Reward[](streams.length + 1);
        rewards[0] = Reward({reward: address(WGAS), amount: feeGmxTracker.claimable(address(this))});

        for (uint256 i = 1; i <= streams.length; i++) {
            rewards[i - 1] = _readStream(streams[i - 1]);
        }
        return rewards;
    }

    function _getRewards() internal override {
        super._getRewards();
        feeGmxTracker.claim(address(this));
    }

    function totalDeposits() public view override returns (uint256) {
        return stakedGmxTracker.depositBalances(address(this), address(depositToken));
    }

    function _emergencyWithdraw() internal override {
        gmxRewardRouter.unstakeGmx(totalDeposits());
    }
}
