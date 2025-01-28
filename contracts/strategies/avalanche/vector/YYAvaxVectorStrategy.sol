// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VectorStrategyForSAV2.sol";
import "./../platypus/interfaces/IPlatypusAsset.sol";
import "./../platypus/interfaces/IPlatypusPool.sol";

contract YYAvaxVectorStrategy is VectorStrategyForSAV2 {
    address public constant yyAVAX = 0xF7D9281e8e363584973F946201b82ba72C965D27;
    IPlatypusPool immutable pool;

    constructor(
        VectorStrategyForSAV2Settings memory _vectorStrategyForSAV2Settings,
        VariableRewardsStrategySettings memory _variableRewardsStrategySettings,
        StrategySettings memory _strategySettings
    ) VectorStrategyForSAV2(_vectorStrategyForSAV2Settings, _variableRewardsStrategySettings, _strategySettings) {
        (, , , address asset, , , , , ) = IVectorMainStaking(_vectorStrategyForSAV2Settings.vectorMainStaking)
            .getPoolInfo(yyAVAX);
        pool = IPlatypusPool(IPlatypusAsset(asset).pool());
    }

    function assignSwapPairSafely(address _swapPairDepositToken) internal virtual override {
        if (address(depositToken) != yyAVAX) {
            super.assignSwapPairSafely(_swapPairDepositToken);
        }
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        Reward[] memory rewards = super._pendingRewards();
        for (uint256 i = 0; i < rewards.length; i++) {
            if (rewards[i].reward == yyAVAX) {
                (rewards[i].amount, ) = pool.quotePotentialSwap(yyAVAX, address(WAVAX), rewards[i].amount);
                rewards[i].reward = address(WAVAX);
            }
        }
        return rewards;
    }

    function _getRewards() internal override {
        super._getRewards();
        uint256 yyAvaxBalance = IERC20(yyAVAX).balanceOf(address(this));
        if (yyAvaxBalance > 0) {
            IERC20(yyAVAX).approve(address(pool), yyAvaxBalance);
            pool.swap(yyAVAX, address(WAVAX), yyAvaxBalance, 0, address(this), type(uint256).max);
            IERC20(yyAVAX).approve(address(pool), 0);
        }
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal override returns (uint256 toAmount) {
        if (address(depositToken) == yyAVAX) {
            WAVAX.approve(address(pool), _fromAmount);
            (toAmount, ) = pool.swap(address(WAVAX), yyAVAX, _fromAmount, 0, address(this), type(uint256).max);
            WAVAX.approve(address(pool), 0);
        } else {
            return super._convertRewardTokenToDepositToken(_fromAmount);
        }
    }
}
