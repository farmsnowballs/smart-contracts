// SPDX-License-Identifier: MIT
pragma experimental ABIEncoderV2;
pragma solidity 0.7.3;

import "../interfaces/IYYStaking.sol";
import "./VariableRewardsStrategy.sol";

contract CompoundingYYStaking is VariableRewardsStrategy {
    using SafeMath for uint256;

    IYYStaking public stakingContract;
    address public swapPairToken;
    address public swapPairPreSwap;
    address public preSwapToken;

    constructor(
        string memory _name,
        address _depositToken,
        address _preSwapToken,
        address _swapPairPreSwap,
        address _swapPairToken,
        RewardSwapPairs[] memory _rewardSwapPairs,
        address _stakingContract,
        address _timelock,
        StrategySettings memory _strategySettings
    ) VariableRewardsStrategy(_name, _depositToken, _rewardSwapPairs, _timelock, _strategySettings) {
        swapPairPreSwap = _swapPairPreSwap;
        swapPairToken = _swapPairToken;
        preSwapToken = _preSwapToken;
        stakingContract = IYYStaking(_stakingContract);
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal override returns (uint256 toAmount) {
        if (swapPairPreSwap > address(0)) {
            _fromAmount = DexLibrary.swap(
                _fromAmount,
                address(rewardToken),
                address(preSwapToken),
                IPair(swapPairPreSwap)
            );
        }
        return DexLibrary.swap(_fromAmount, address(preSwapToken), address(depositToken), IPair(swapPairToken));
    }

    function _getDepositFeeBips() internal view virtual override returns (uint256) {
        return stakingContract.depositFeePercent();
    }

    function _depositToStakingContract(uint256 _amount) internal override {
        depositToken.approve(address(stakingContract), _amount);
        stakingContract.deposit(_amount);
        depositToken.approve(address(stakingContract), 0);
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
        (uint256 amount, ) = stakingContract.getUserInfo(address(this), address(0));
        return amount;
    }
}
