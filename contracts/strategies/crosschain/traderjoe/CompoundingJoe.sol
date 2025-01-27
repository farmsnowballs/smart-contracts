// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../BaseStrategy.sol";

import "./interfaces/IStableJoeStaking.sol";

contract CompoundingJoe is BaseStrategy {
    IStableJoeStaking public stakingContract;

    constructor(
        address _stakingContract,
        BaseStrategySettings memory _settings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_settings, _strategySettings) {
        stakingContract = IStableJoeStaking(_stakingContract);
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(stakingContract), _amount);
        stakingContract.deposit(_amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        stakingContract.withdraw(_amount);
        return _amount;
    }

    function _emergencyWithdraw() internal override {
        stakingContract.emergencyWithdraw();
        depositToken.approve(address(stakingContract), 0);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        uint256 rewardCount = stakingContract.rewardTokensLength();
        Reward[] memory pendingRewards = new Reward[](rewardCount);
        for (uint256 i = 0; i < rewardCount; i++) {
            address rewardToken = stakingContract.rewardTokens(i);
            uint256 amount = stakingContract.pendingReward(address(this), rewardToken);
            pendingRewards[i] = Reward({reward: rewardToken, amount: amount});
        }
        return pendingRewards;
    }

    function _getRewards() internal override {
        stakingContract.deposit(0);
    }

    function totalDeposits() public view override returns (uint256) {
        (uint256 amount,) = stakingContract.getUserInfo(address(this), address(0));
        return amount;
    }

    function _getDepositFeeBips() internal view override returns (uint256) {
        return stakingContract.depositFeePercent();
    }

    function _getWithdrawFeeBips() internal pure override returns (uint256) {
        return 0;
    }

    function _bip() internal view override returns (uint256) {
        return stakingContract.DEPOSIT_FEE_PERCENT_PRECISION();
    }
}
