// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "../../BaseStrategy.sol";

import "./interfaces/IReservedLevelOmniStaking.sol";
import "./interfaces/ILevelPool.sol";
import "./interfaces/ILevelLiquidityCalculator.sol";
import "./interfaces/ILevelOracle.sol";

contract CompoundingLVL is BaseStrategy {
    IReservedLevelOmniStaking public immutable levelStaking;
    ILevelPool public immutable levelPool;
    ILevelLiquidityCalculator public immutable liquidityCalculator;
    ILevelOracle public immutable levelOracle;

    constructor(
        address _reservedLevelOmniStaking,
        address _levelLiquidityPool,
        BaseStrategySettings memory _baseStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_baseStrategySettings, _strategySettings) {
        levelStaking = IReservedLevelOmniStaking(_reservedLevelOmniStaking);
        levelPool = ILevelPool(_levelLiquidityPool);
        liquidityCalculator = ILevelLiquidityCalculator(levelPool.liquidityCalculator());
        levelOracle = ILevelOracle(levelPool.oracle());
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(levelStaking), _amount);
        levelStaking.stake(address(this), _amount);
    }

    function _getDepositFeeBips() internal view override returns (uint256) {
        return levelStaking.STAKING_TAX();
    }

    function _bip() internal view override returns (uint256) {
        return levelStaking.STAKING_TAX_PRECISION();
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        levelStaking.unstake(address(this), _amount);
        _withdrawAmount = _amount;
    }

    function _emergencyWithdraw() internal override {
        levelStaking.unstake(address(this), totalDeposits());
        depositToken.approve(address(levelStaking), 0);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        uint256 pendingLLP = levelStaking.pendingRewards(levelStaking.currentEpoch() - 1, address(this));
        if (pendingLLP > 0) {
            Reward[] memory pendingRewards = new Reward[](1);
            pendingRewards[0].reward = _lowestFeeAsset(pendingLLP);
            (pendingRewards[0].amount,) =
                liquidityCalculator.calcRemoveLiquidity(levelStaking.LLP(), pendingRewards[0].reward, pendingLLP);
            return pendingRewards;
        }
        return new Reward[](0);
    }

    function _lowestFeeAsset(uint256 _lpAmount) internal view returns (address lowestFeeAsset) {
        (address[] memory assets,) = levelPool.getAllAssets();
        uint256 lowestFee = type(uint256).max;
        for (uint256 i; i < assets.length; i++) {
            if (levelStaking.claimableTokens(assets[i])) {
                uint256 price = levelOracle.getPrice(assets[i], true);
                uint256 fee = liquidityCalculator.calcAddRemoveLiquidityFee(assets[i], price, _lpAmount, false);
                if (fee < lowestFee) {
                    lowestFee = fee;
                    lowestFeeAsset = assets[i];
                }
            }
        }
    }

    function _getRewards() internal override {
        Reward[] memory pendingRewards = _pendingRewards();
        if (pendingRewards.length > 0 && pendingRewards[0].amount > 0) {
            levelStaking.claimRewardsToSingleToken(
                levelStaking.currentEpoch() - 1, address(this), pendingRewards[0].reward, 0
            );
        }
    }

    function totalDeposits() public view override returns (uint256) {
        return levelStaking.stakedAmounts(address(this));
    }
}
