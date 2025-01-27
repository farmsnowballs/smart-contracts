// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../BaseStrategy.sol";
import "./interfaces/IPoolDepositor.sol";
import "./interfaces/IWombexRewardPool.sol";
import "./interfaces/IWombatAsset.sol";
import "./interfaces/IWombatPool.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/ITokenMinter.sol";

contract WombexStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    address private constant WOM = 0x7B5EB3940021Ec0e8e463D5dBB4B7B09a89DDF96;
    address private constant WMX = 0x5190F06EaceFA2C552dc6BD5e763b81C73293293;

    struct WombexStrategySettings {
        address poolDepositor;
        address rewardPool;
    }

    IPoolDepositor public immutable poolDepositor;
    IWombexRewardPool public immutable rewardPool;
    IWombatAsset public immutable wombatAsset;
    IWombatPool public immutable wombatPool;
    IBooster public immutable booster;
    uint256 public immutable pid;

    constructor(
        WombexStrategySettings memory _wombexStrategySettings,
        BaseStrategySettings memory baseStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(baseStrategySettings, _strategySettings) {
        poolDepositor = IPoolDepositor(_wombexStrategySettings.poolDepositor);
        rewardPool = IWombexRewardPool(_wombexStrategySettings.rewardPool);
        wombatAsset = IWombatAsset(rewardPool.asset());
        wombatPool = IWombatPool(wombatAsset.pool());
        booster = IBooster(poolDepositor.booster());
        pid = poolDepositor.lpTokenToPid(rewardPool.asset());
    }

    function _calculateDepositBonus(uint256 _amount) internal override returns (uint256 bonus) {
        wombatPool.mintFee(address(depositToken));
        (, bonus) = wombatPool.quotePotentialDeposit(address(depositToken), _amount);
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(poolDepositor), _amount);
        poolDepositor.deposit(address(wombatAsset), _amount, 0, true);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        uint256 lpBalance = rewardPool.balanceOf(address(this));
        uint256 liquidity = (_amount * lpBalance) / totalDeposits();
        liquidity = liquidity > lpBalance ? lpBalance : liquidity;
        rewardPool.withdrawAndUnwrap(liquidity, false);
        (uint256 expectedAmount,) = wombatPool.quotePotentialWithdraw(address(depositToken), liquidity);
        IERC20(address(wombatAsset)).approve(address(wombatPool), liquidity);
        _withdrawAmount =
            wombatPool.withdraw(address(depositToken), liquidity, expectedAmount, address(this), type(uint256).max);
    }

    function _emergencyWithdraw() internal override {
        depositToken.approve(address(poolDepositor), 0);
        rewardPool.withdrawAllAndUnwrap(false);
        uint256 assetBalance = IERC20(address(wombatAsset)).balanceOf(address(this));
        IERC20(address(wombatAsset)).approve(address(wombatPool), assetBalance);
        wombatPool.withdraw(address(depositToken), assetBalance, 0, address(this), type(uint256).max);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        (address[] memory tokens, uint256[] memory amounts) = rewardPool.claimableRewards(address(this));
        Reward[] memory pendingRewards = new Reward[](tokens.length + 1);
        uint256 womAmount;
        for (uint256 i = 0; i < tokens.length; i++) {
            pendingRewards[i] = Reward({reward: tokens[i], amount: amounts[i]});
            if (tokens[i] == WOM) {
                womAmount = amounts[i];
            }
        }
        if (womAmount > 0) {
            uint256 poolMintRatio = booster.customMintRatio(pid);
            if (poolMintRatio == 0) {
                poolMintRatio = booster.mintRatio();
            }
            if (poolMintRatio > 0) {
                uint256 wmxAmount = (womAmount * poolMintRatio) / BIPS_DIVISOR;
                address reservoirMinter = booster.reservoirMinter();
                ITokenMinter tokenMinter =
                    reservoirMinter == address(0) ? ITokenMinter(booster.cvx()) : ITokenMinter(reservoirMinter);
                pendingRewards[tokens.length] = Reward({reward: WMX, amount: tokenMinter.getFactAmounMint(wmxAmount)});
            }
        }
        return pendingRewards;
    }

    function _getRewards() internal override {
        rewardPool.getReward();
    }

    function totalDeposits() public view override returns (uint256) {
        uint256 liquidity = rewardPool.balanceOf(address(this));
        uint256 deposits = (wombatAsset.liability() * liquidity) / wombatAsset.totalSupply();
        return fromWad(deposits, depositToken.decimals());
    }

    function fromWad(uint256 x, uint8 d) internal pure returns (uint256) {
        if (d < 18) {
            return (x / (10 ** (18 - d)));
        } else if (d > 18) {
            return x * 10 ** (d - 18);
        }
        return x;
    }
}
