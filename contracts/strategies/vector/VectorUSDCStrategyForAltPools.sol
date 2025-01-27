// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../VariableRewardsStrategyForSA.sol";
import "../../lib/SafeERC20.sol";
import "../../lib/SafeMath.sol";
import "../../interfaces/IBoosterFeeCollector.sol";

import "./interfaces/IVectorMainStaking.sol";
import "./interfaces/IVectorPoolHelperV2.sol";

contract VectorUSDCStrategyForAltPools is VariableRewardsStrategyForSA {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 private constant PTP = IERC20(0x22d4002028f537599bE9f666d1c4Fa138522f9c8);
    IERC20 private constant VTX = IERC20(0x5817D4F0b62A59b17f75207DA1848C2cE75e7AF4);

    IVectorMainStaking public immutable vectorMainStaking;
    IBoosterFeeCollector public boosterFeeCollector;

    address public immutable platypusAsset;

    constructor(
        string memory _name,
        address _depositToken,
        address _platypusAsset,
        address _swapPairDepositToken,
        RewardSwapPairs[] memory _rewardSwapPairs,
        address _stakingContract,
        address _boosterFeeCollector,
        address _timelock,
        StrategySettings memory _strategySettings
    )
        VariableRewardsStrategyForSA(
            _name,
            _depositToken,
            _swapPairDepositToken,
            _rewardSwapPairs,
            _timelock,
            _strategySettings
        )
    {
        vectorMainStaking = IVectorMainStaking(_stakingContract);
        platypusAsset = _platypusAsset;
        boosterFeeCollector = IBoosterFeeCollector(_boosterFeeCollector);
    }

    function updateBoosterFeeCollector(address _collector) public onlyOwner {
        boosterFeeCollector = IBoosterFeeCollector(_collector);
    }

    function _depositToStakingContract(uint256 _amount) internal override {
        IVectorPoolHelperV2 vectorPoolHelper = _vectorPoolHelper();
        depositToken.approve(address(vectorPoolHelper.mainStaking()), _amount);
        vectorPoolHelper.deposit(_amount);
        depositToken.approve(address(vectorPoolHelper.mainStaking()), 0);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _vectorPoolHelper().withdraw(_amount, 0);
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        return balanceAfter.sub(balanceBefore);
    }

    function _emergencyWithdraw() internal override {
        IVectorPoolHelperV2 vectorPoolHelper = _vectorPoolHelper();
        depositToken.approve(address(vectorPoolHelper), 0);
        vectorPoolHelper.withdraw(totalDeposits(), 0);
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        IVectorPoolHelperV2 vectorPoolHelper = _vectorPoolHelper();
        uint256 count = rewardCount;
        Reward[] memory pendingRewards = new Reward[](count);
        (uint256 pendingVTX, uint256 pendingPTP) = vectorPoolHelper.earned(address(PTP));
        uint256 boostFee = boosterFeeCollector.calculateBoostFee(address(this), pendingPTP);
        pendingRewards[0] = Reward({reward: address(PTP), amount: pendingPTP.sub(boostFee)});
        pendingRewards[1] = Reward({reward: address(VTX), amount: pendingVTX});
        uint256 offset = 2;
        for (uint256 i = 0; i < count; i++) {
            address rewardToken = supportedRewards[i];
            if (rewardToken == address(PTP) || rewardToken == address(VTX)) {
                continue;
            }
            (, uint256 pendingAdditionalReward) = vectorPoolHelper.earned(address(rewardToken));
            pendingRewards[offset] = Reward({reward: rewardToken, amount: pendingAdditionalReward});
            offset++;
        }
        return pendingRewards;
    }

    function _getRewards() internal override {
        uint256 ptpBalanceBefore = PTP.balanceOf(address(this));
        _vectorPoolHelper().getReward();
        uint256 amount = PTP.balanceOf(address(this)).sub(ptpBalanceBefore);
        uint256 boostFee = boosterFeeCollector.calculateBoostFee(address(this), amount);
        PTP.safeTransfer(address(boosterFeeCollector), boostFee);
    }

    function totalDeposits() public view override returns (uint256) {
        return _vectorPoolHelper().depositTokenBalance(address(this));
    }

    function _vectorPoolHelper() private view returns (IVectorPoolHelperV2) {
        (, , , , , , , , address helper) = vectorMainStaking.getPoolInfo(platypusAsset);
        return IVectorPoolHelperV2(helper);
    }
}
