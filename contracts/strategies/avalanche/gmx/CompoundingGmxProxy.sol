// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../interfaces/IYakStrategy.sol";
import "../../../lib/SafeERC20.sol";

import "./interfaces/IGmxDepositor.sol";
import "./interfaces/IGmxRewardRouter.sol";
import "./interfaces/IGmxRewardTracker.sol";
import "./interfaces/ICompoundingGmxProxy.sol";
import "./GmxDepositor.sol";

library SafeProxy {
    function safeExecute(
        IGmxDepositor gmxDepositor,
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnValue) = gmxDepositor.execute(target, value, data);
        if (!success) revert("GmxProxy::safeExecute failed");
        return returnValue;
    }
}

contract CompoundingGmxProxy is ICompoundingGmxProxy {
    using SafeProxy for IGmxDepositor;
    using SafeERC20 for IERC20;

    address internal constant GMX = 0x62edc0692BD897D2295872a9FFCac5425011c661;

    IGmxDepositor public immutable gmxDepositor;
    IGmxDepositor public immutable esGmxHolder;

    address public immutable override gmxRewardRouter;

    address public immutable gmxRewardTracker;
    address public immutable feeGmxTracker;

    address public devAddr;
    address public approvedStrategy;

    modifier onlyDev() {
        require(msg.sender == devAddr, "GmxProxy::onlyDev");
        _;
    }

    modifier onlyGmxStrategy() {
        require(approvedStrategy == msg.sender, "GmxProxy::onlyGmxStrategy");
        _;
    }

    constructor(
        address _gmxDepositor,
        address _esGmxHolder,
        address _gmxRewardRouter,
        address _devAddr
    ) {
        require(_gmxDepositor > address(0), "GmxProxy::Invalid depositor address provided");
        require(_gmxRewardRouter > address(0), "GmxProxy::Invalid reward router address provided");
        require(_devAddr > address(0), "GmxProxy::Invalid dev address provided");
        devAddr = _devAddr;
        gmxDepositor = IGmxDepositor(_gmxDepositor);
        esGmxHolder = IGmxDepositor(_esGmxHolder);
        gmxRewardRouter = _gmxRewardRouter;
        gmxRewardTracker = IGmxRewardRouter(_gmxRewardRouter).stakedGmxTracker();
        feeGmxTracker = IGmxRewardRouter(_gmxRewardRouter).feeGmxTracker();
    }

    function updateDevAddr(address newValue) public onlyDev {
        require(newValue > address(0), "GmxProxy::Invalid dev address provided");
        devAddr = newValue;
    }

    function approveStrategy(address _strategy) external onlyDev {
        require(approvedStrategy == address(0), "GmxProxy::Strategy already approved");
        approvedStrategy = _strategy;
    }

    function stake(uint256 _amount) external override onlyGmxStrategy {
        gmxDepositor.safeExecute(
            GMX,
            0,
            abi.encodeWithSignature("approve(address,uint256)", gmxRewardTracker, _amount)
        );
        gmxDepositor.safeExecute(gmxRewardRouter, 0, abi.encodeWithSignature("stakeGmx(uint256)", _amount));
    }

    function withdraw(uint256 _amount) external override onlyGmxStrategy {
        _withdraw(_amount);
    }

    function _withdraw(uint256 _amount) private {
        gmxDepositor.safeExecute(gmxRewardRouter, 0, abi.encodeWithSignature("unstakeGmx(uint256)", _amount));
        gmxDepositor.safeExecute(GMX, 0, abi.encodeWithSignature("transfer(address,uint256)", msg.sender, _amount));
    }

    function pendingRewards() external view override returns (uint256 pending) {
        pending += IGmxRewardTracker(feeGmxTracker).claimable(address(gmxDepositor));
        pending += IGmxRewardTracker(feeGmxTracker).claimable(address(esGmxHolder));
    }

    function claimReward() external override onlyGmxStrategy {
        _claim(address(gmxDepositor));
        _compoundEsGmx(address(gmxDepositor));
        _claim(address(esGmxHolder));
        _compoundEsGmx(address(esGmxHolder));
    }

    function _claim(address _depositor) internal {
        IGmxDepositor(_depositor).safeExecute(
            feeGmxTracker,
            0,
            abi.encodeWithSignature("claim(address)", approvedStrategy)
        );
    }

    function _compoundEsGmx(address _depositor) internal {
        IGmxDepositor(_depositor).safeExecute(
            gmxRewardRouter,
            0,
            abi.encodeWithSignature(
                "handleRewards(bool,bool,bool,bool,bool,bool,bool)",
                false, // _shouldClaimGmx
                false, // _shouldStakeGmx
                true, // _shouldClaimEsGmx
                true, // _shouldStakeEsGmx
                true, // _shouldStakeMultiplierPoints
                false, // _shouldClaimWeth
                false // _shouldConvertWethToEth
            )
        );
    }

    function totalDeposits() public view override returns (uint256) {
        address rewardTracker = IGmxRewardRouter(gmxRewardRouter).stakedGmxTracker();
        return IGmxRewardTracker(rewardTracker).depositBalances(address(gmxDepositor), GMX);
    }

    function emergencyWithdraw(uint256 _balance) external override onlyGmxStrategy {
        _withdraw(_balance);
    }
}
