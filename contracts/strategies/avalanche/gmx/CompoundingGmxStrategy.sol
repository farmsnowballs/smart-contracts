// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "../../SingleRewardStrategyForSA.sol";
import "../../../interfaces/IERC20.sol";
import "../../../lib/SafeERC20.sol";

import "./interfaces/IGmxProxy.sol";
import "./interfaces/ICompoundingGmxProxy.sol";

contract CompoundingGmxStrategy is SingleRewardStrategyForSA {
    using SafeERC20 for IERC20;

    ICompoundingGmxProxy public proxy;

    constructor(
        address _swapPairDepositToken,
        address _gmxProxy,
        SingleRewardStrategySettings memory _settings,
        StrategySettings memory _strategySettings
    ) SingleRewardStrategyForSA(_swapPairDepositToken, _settings, _strategySettings) {
        proxy = ICompoundingGmxProxy(_gmxProxy);
    }

    function setProxy(address _proxy) external onlyOwner {
        proxy = ICompoundingGmxProxy(_proxy);
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.safeTransfer(address(proxy.gmxDepositor()), _amount);
        proxy.stake(_amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 _withdrawAmount) {
        proxy.withdraw(_amount);
        return _amount;
    }

    function _pendingRewards() internal view override returns (uint256) {
        return proxy.pendingRewards();
    }

    function _getRewards() internal override {
        proxy.claimReward();
    }

    function totalDeposits() public view override returns (uint256) {
        return proxy.totalDeposits();
    }

    function _emergencyWithdraw() internal override {
        uint256 balance = totalDeposits();
        proxy.emergencyWithdraw(balance);
    }
}
