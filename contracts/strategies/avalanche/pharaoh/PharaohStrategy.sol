// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../../BaseStrategy.sol";

import "./../../../interfaces/IPair.sol";
import "./interfaces/IGauge.sol";
import "./interfaces/IRouter.sol";

contract PharaohStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IGauge public immutable gauge;

    address internal immutable token0;
    address internal immutable token1;

    constructor(
        address _gauge,
        BaseStrategySettings memory _variableRewardsStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_variableRewardsStrategySettings, _strategySettings) {
        require(!IPair(address(depositToken)).stable(), "PharaohStrategy::Stable pairs not supported");
        gauge = IGauge(_gauge);
        token0 = IPair(address(depositToken)).token0();
        token1 = IPair(address(depositToken)).token1();
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        IERC20(depositToken).approve(address(gauge), _amount);
        gauge.deposit(_amount, 0);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        gauge.withdraw(_amount);
        return _amount;
    }

    function _pendingRewards() internal view virtual override returns (Reward[] memory) {
        uint256 count = supportedRewards.length;
        Reward[] memory rewards = new Reward[](count);
        for (uint256 i = 0; i < count; i++) {
            address token = supportedRewards[i];
            uint256 amount = gauge.earned(token, address(this));
            rewards[i] = Reward({reward: token, amount: amount});
        }
        return rewards;
    }

    function _getRewards() internal virtual override {
        gauge.getReward(address(this), supportedRewards);
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

    function totalDeposits() public view override returns (uint256) {
        return gauge.balanceOf(address(this));
    }

    function _emergencyWithdraw() internal override {
        gauge.withdrawAll();
    }
}
