// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "../../BaseStrategy.sol";
import "../../../interfaces/IERC20.sol";
import "../../../interfaces/IPair.sol";

import "./interfaces/IMiniChefV2.sol";
import "./interfaces/IPangolinRewarder.sol";

contract PangolinV2StrategyForLP is BaseStrategy {
    using SafeERC20 for IERC20;

    IMiniChefV2 public immutable miniChef;
    uint256 public immutable PID;
    address public immutable poolRewardToken;

    address internal immutable token0;
    address internal immutable token1;

    constructor(
        address _stakingContract,
        uint256 _pid,
        BaseStrategySettings memory _baseStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_baseStrategySettings, _strategySettings) {
        PID = _pid;
        miniChef = IMiniChefV2(_stakingContract);
        poolRewardToken = miniChef.REWARD();
        token0 = IPair(address(depositToken)).token0();
        token1 = IPair(address(depositToken)).token1();
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(miniChef), _amount);
        miniChef.deposit(PID, _amount, address(this));
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        miniChef.withdraw(PID, _amount, address(this));
        return _amount;
    }

    function _pendingRewards() internal view virtual override returns (Reward[] memory) {
        uint256 poolRewardAmount = miniChef.pendingReward(PID, address(this));
        IPangolinRewarder rewarder = IPangolinRewarder(miniChef.rewarder(PID));
        Reward[] memory pendingRewards;
        if (address(rewarder) > address(0)) {
            (address[] memory rewardTokens, uint256[] memory rewardAmounts) =
                rewarder.pendingTokens(0, address(this), poolRewardAmount);
            pendingRewards = new Reward[](rewardTokens.length + 1);
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                pendingRewards[i + 1] = Reward({reward: rewardTokens[i], amount: rewardAmounts[i]});
            }
        } else {
            pendingRewards = new Reward[](1);
        }
        pendingRewards[0] = Reward({reward: poolRewardToken, amount: poolRewardAmount});
        return pendingRewards;
    }

    function _getRewards() internal virtual override {
        miniChef.harvest(PID, address(this));
    }

    function _convertRewardTokenToDepositToken(uint256 fromAmount) internal override returns (uint256 toAmount) {
        fromAmount = fromAmount / 2;
        if (address(rewardToken) != token0) {
            FormattedOffer memory offer = simpleRouter.query(fromAmount, address(rewardToken), token0);
            rewardToken.approve(address(simpleRouter), fromAmount);
            simpleRouter.swap(offer);
        }
        if (address(rewardToken) != token1) {
            FormattedOffer memory offer = simpleRouter.query(fromAmount, address(rewardToken), token1);
            rewardToken.approve(address(simpleRouter), fromAmount);
            simpleRouter.swap(offer);
        }
        toAmount = addLiquidity(
            address(depositToken), IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this))
        );
    }

    function addLiquidity(address depositToken, uint256 maxAmountIn0, uint256 maxAmountIn1)
        internal
        returns (uint256)
    {
        (uint112 reserve0, uint112 reserve1,) = IPair(address(depositToken)).getReserves();
        uint256 amountIn1 = _quoteLiquidityAmountOut(maxAmountIn0, reserve0, reserve1);
        if (amountIn1 > maxAmountIn1) {
            amountIn1 = maxAmountIn1;
            maxAmountIn0 = _quoteLiquidityAmountOut(maxAmountIn1, reserve1, reserve0);
        }
        IERC20(token0).safeTransfer(depositToken, maxAmountIn0);
        IERC20(token1).safeTransfer(depositToken, amountIn1);

        return IPair(depositToken).mint(address(this));
    }

    function _quoteLiquidityAmountOut(uint256 amountIn, uint256 reserve0, uint256 reserve1)
        private
        pure
        returns (uint256)
    {
        return (amountIn * reserve1) / reserve0;
    }

    function totalDeposits() public view override returns (uint256 amount) {
        (amount,) = miniChef.userInfo(PID, address(this));
    }

    function _emergencyWithdraw() internal override {
        miniChef.emergencyWithdraw(PID, address(this));
        depositToken.approve(address(miniChef), 0);
    }
}
