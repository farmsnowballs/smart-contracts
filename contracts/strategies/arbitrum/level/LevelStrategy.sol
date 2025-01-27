// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "../../BaseStrategy.sol";

import "./interfaces/ILevelMasterV2.sol";
import "./interfaces/ILevelPool.sol";

contract LevelStrategy is BaseStrategy {
    address private constant LVL = 0xB64E280e9D1B5DbEc4AcceDb2257A87b400DB149;

    ILevelMasterV2 public immutable levelMaster;
    ILevelPool public immutable levelPool;
    uint256 public immutable PID;

    address lpTokenIn;

    constructor(
        address _stakingContract,
        uint256 _pid,
        address _lpTokenIn,
        BaseStrategySettings memory _variableRewardsStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_variableRewardsStrategySettings, _strategySettings) {
        PID = _pid;
        levelMaster = ILevelMasterV2(_stakingContract);
        levelPool = ILevelPool(levelMaster.levelPool());
        lpTokenIn = _lpTokenIn;
    }

    function updateLPTokenIn(address _lpTokenIn) external onlyDev {
        lpTokenIn = _lpTokenIn;
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(levelMaster), _amount);
        levelMaster.deposit(PID, _amount, address(this));
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        levelMaster.withdraw(PID, _amount, address(this));
        _withdrawAmount = _amount;
    }

    function _emergencyWithdraw() internal override {
        levelMaster.withdraw(PID, totalDeposits(), address(this));
        depositToken.approve(address(levelMaster), 0);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        uint256 pendingReward = levelMaster.pendingReward(PID, address(this));
        Reward[] memory pendingRewards = new Reward[](1);
        pendingRewards[0] = Reward({reward: LVL, amount: pendingReward});
        return pendingRewards;
    }

    function _getRewards() internal override {
        levelMaster.harvest(PID, address(this));
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal override returns (uint256 toAmount) {
        if (lpTokenIn != address(rewardToken)) {
            FormattedOffer memory offer = simpleRouter.query(_fromAmount, address(rewardToken), lpTokenIn);
            _fromAmount = _swap(offer);
        }
        uint256 before = depositToken.balanceOf(address(this));
        IERC20(lpTokenIn).approve(address(levelPool), _fromAmount);
        levelPool.addLiquidity(address(depositToken), lpTokenIn, _fromAmount, 0, address(this));
        return depositToken.balanceOf(address(this)) - before;
    }

    function totalDeposits() public view override returns (uint256) {
        (uint256 amount,) = levelMaster.userInfo(PID, address(this));
        return amount;
    }
}
