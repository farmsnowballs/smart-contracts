// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "../../MasterChefStrategy.sol";

import "./interfaces/IKassandraPool.sol";
import "./interfaces/IKassandraStaking.sol";

contract KassandraIndexStrategyK3C is MasterChefStrategy {
    using SafeMath for uint256;

    IKassandraStaking public stakingContract;
    IKassandraPool public kassandraPool;

    constructor(
        string memory _name,
        address _depositToken,
        address _poolRewardToken,
        address _swapPairPoolReward,
        address _stakingContract,
        uint256 _pid,
        address _timelock,
        StrategySettings memory _strategySettings
    )
        MasterChefStrategy(
            _name,
            _poolRewardToken,
            _swapPairPoolReward,
            address(0),
            _timelock,
            _pid,
            _strategySettings
        )
    {
        stakingContract = IKassandraStaking(_stakingContract);
        kassandraPool = IKassandraPool(_depositToken);
    }

    function _getDepositFeeBips(
        uint256 /* pid */
    ) internal pure override returns (uint256) {
        return 0;
    }

    function _getWithdrawFeeBips(
        uint256 /* pid */
    ) internal pure override returns (uint256) {
        return 0;
    }

    function _depositMasterchef(uint256 _pid, uint256 _amount) internal override {
        depositToken.approve(address(stakingContract), _amount);
        stakingContract.stake(_pid, _amount, address(this), address(this));
    }

    function _withdrawMasterchef(uint256 _pid, uint256 _amount) internal override {
        stakingContract.withdraw(_pid, _amount);
    }

    function _pendingRewards(uint256 _pid, address _user)
        internal
        view
        override
        returns (
            uint256,
            uint256,
            address
        )
    {
        uint256 pendingReward = stakingContract.earned(_pid, address(_user));
        return (pendingReward, 0, address(0));
    }

    function _getRewards(uint256 _pid) internal override {
        stakingContract.getReward(_pid);
    }

    function _getDepositBalance(uint256 pid, address user) internal view override returns (uint256 amount) {
        return stakingContract.balanceOf(pid, user);
    }

    function _bip() internal pure override returns (uint256) {
        return 10000;
    }

    function _convertRewardTokenToDepositToken(uint256 fromAmount) internal override returns (uint256 toAmount) {
        rewardToken.approve(address(kassandraPool), fromAmount);
        return kassandraPool.joinswapExternAmountIn(address(rewardToken), fromAmount, 0);
    }

    function _emergencyWithdraw(uint256 _pid) internal override {
        depositToken.approve(address(stakingContract), 0);
        stakingContract.exit(_pid);
    }
}
