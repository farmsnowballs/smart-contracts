// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../BaseStrategy.sol";

import "./interfaces/IGauge.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPool.sol";

abstract contract CurveStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    struct CurveStrategySettings {
        address gauge;
        address lpTokenIn;
        uint256 lpTokenCount;
        address crv;
    }

    IGauge public immutable stakingContract;
    address public immutable lpTokenIn;
    IFactory public immutable factory;

    uint256 immutable lpTokenCount;
    uint256 immutable lpTokenInIndex;
    address immutable CRV;

    constructor(
        CurveStrategySettings memory _curveStrategySettings,
        BaseStrategySettings memory _settings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_settings, _strategySettings) {
        stakingContract = IGauge(_curveStrategySettings.gauge);
        CRV = _curveStrategySettings.crv;
        factory = IFactory(stakingContract.factory());
        lpTokenIn = _curveStrategySettings.lpTokenIn;
        lpTokenCount = _curveStrategySettings.lpTokenCount;
        uint256 tokenIndex = lpTokenCount;
        for (uint256 i = 0; i < lpTokenCount; i++) {
            if (lpTokenIn == IPool(address(depositToken)).coins(i)) {
                tokenIndex = i;
            }
        }
        require(tokenIndex < lpTokenCount, "CurveStrategy::Unsupported pool or lpTokenIn");
        lpTokenInIndex = tokenIndex;
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(stakingContract), _amount);
        stakingContract.deposit(_amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        stakingContract.withdraw(_amount);
        return _amount;
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        Reward[] memory pendingRewards = new Reward[](stakingContract.reward_count() + 1);
        for (uint256 i = 0; i < pendingRewards.length - 1; i++) {
            address rewardToken = stakingContract.reward_tokens(i);
            uint256 amount = stakingContract.claimable_reward(address(this), rewardToken);
            pendingRewards[i] = Reward({reward: rewardToken, amount: amount});
        }
        pendingRewards[pendingRewards.length - 1] = Reward({reward: CRV, amount: _pendingCrvRewards()});
        return pendingRewards;
    }

    function _pendingCrvRewards() internal view returns (uint256) {
        uint256 period = stakingContract.period();
        uint256 periodTime = stakingContract.period_timestamp(period);
        uint256 integrateInvSupply = stakingContract.integrate_inv_supply(period);

        if (block.timestamp > periodTime) {
            uint256 workingSupply = stakingContract.working_supply();
            uint256 prevWeekTime = periodTime;
            uint256 weekTime = min((periodTime + 1 weeks) / 1 weeks * 1 weeks, block.timestamp);

            for (uint256 i = 0; i < type(uint256).max; i++) {
                uint256 dt = weekTime - prevWeekTime;

                if (workingSupply != 0) {
                    integrateInvSupply +=
                        stakingContract.inflation_rate(prevWeekTime / 1 weeks) * 10 ** 18 * dt / workingSupply;
                }

                if (weekTime == block.timestamp) break;

                prevWeekTime = weekTime;
                weekTime = min(weekTime + 1 weeks, block.timestamp);
            }
        }

        uint256 userTotal = stakingContract.integrate_fraction(address(this))
            + (
                stakingContract.working_balances(address(this))
                    * (integrateInvSupply - stakingContract.integrate_inv_supply_of(address(this))) / 10 ** 18
            );
        return userTotal - factory.minted(address(this), address(stakingContract));
    }

    function min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }

    function _getRewards() internal override {
        stakingContract.claim_rewards();
        if (factory.is_valid_gauge(address(stakingContract))) {
            factory.mint(address(stakingContract));
        }
    }

    function totalDeposits() public view override returns (uint256) {
        return stakingContract.balanceOf(address(this));
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount)
        internal
        virtual
        override
        returns (uint256 toAmount)
    {
        if (address(rewardToken) != lpTokenIn) {
            FormattedOffer memory offer = simpleRouter.query(_fromAmount, address(rewardToken), lpTokenIn);
            _fromAmount = _swap(offer);
        }

        IERC20(lpTokenIn).approve(address(depositToken), _fromAmount);
        return _addLiquidity(_fromAmount);
    }

    function _emergencyWithdraw() internal override {
        stakingContract.withdraw(totalDeposits());
        depositToken.approve(address(stakingContract), 0);
    }

    function _addLiquidity(uint256 _amountIn) internal virtual returns (uint256 amountOut);
}
