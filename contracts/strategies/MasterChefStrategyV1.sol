// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategy.sol";
import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";

/**
 * @notice Strategy for Frost
 */
abstract contract MasterChefStrategyV1 is YakStrategy {
    using SafeMath for uint256;

    IPair private swapPairToken0;
    IPair private swapPairToken1;
    address private stakingRewards;

    uint256 public PID;

    constructor(
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _swapPairToken0,
        address _swapPairToken1,
        address _stakingRewards,
        address _timelock,
        uint256 _pid,
        uint256 _minTokensToReinvest,
        uint256 _adminFeeBips,
        uint256 _devFeeBips,
        uint256 _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IPair(_depositToken);
        rewardToken = IERC20(_rewardToken);
        PID = _pid;
        devAddr = msg.sender;
        stakingRewards = _stakingRewards;

        assignSwapPairSafely(_swapPairToken0, _swapPairToken1, _rewardToken);
        setAllowances();
        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        emit Reinvest(0, 0);
    }

    /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading reward tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken1
     */
    function assignSwapPairSafely(
        address _swapPairToken0,
        address _swapPairToken1,
        address _rewardToken
    ) private {
        if (
            _rewardToken != IPair(address(depositToken)).token0() &&
            _rewardToken != IPair(address(depositToken)).token1()
        ) {
            // deployment checks for non-pool2
            require(
                _swapPairToken0 > address(0),
                "Swap pair 0 is necessary but not supplied"
            );
            require(
                _swapPairToken1 > address(0),
                "Swap pair 1 is necessary but not supplied"
            );
            swapPairToken0 = IPair(_swapPairToken0);
            swapPairToken1 = IPair(_swapPairToken1);
            require(
                swapPairToken0.token0() == _rewardToken ||
                    swapPairToken0.token1() == _rewardToken,
                "Swap pair supplied does not have the reward token as one of it's pair"
            );
            require(
                swapPairToken0.token0() ==
                    IPair(address(depositToken)).token0() ||
                    swapPairToken0.token1() ==
                    IPair(address(depositToken)).token0(),
                "Swap pair 0 supplied does not match the pair in question"
            );
            require(
                swapPairToken1.token0() ==
                    IPair(address(depositToken)).token1() ||
                    swapPairToken1.token1() ==
                    IPair(address(depositToken)).token1(),
                "Swap pair 1 supplied does not match the pair in question"
            );
        } else if (_rewardToken == IPair(address(depositToken)).token0()) {
            swapPairToken1 = IPair(address(depositToken));
        } else if (_rewardToken == IPair(address(depositToken)).token1()) {
            swapPairToken0 = IPair(address(depositToken));
        }
    }

    /**
     * @notice Approve tokens for use in Strategy
     * @dev Restricted to avoid griefing attacks
     */
    function setAllowances() public override onlyOwner {
        depositToken.approve(stakingRewards, type(uint256).max);
    }

    /**
     * @notice Deposit tokens to receive receipt tokens
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external override {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Deposit using Permit
     * @param amount Amount of tokens to deposit
     * @param deadline The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        depositToken.permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint256 amount) external override {
        _deposit(account, amount);
    }

    function _deposit(address account, uint256 amount) internal {
        require(DEPOSITS_ENABLED == true, "MasterChefStrategyV1::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            uint256 unclaimedRewards = checkReward();
            if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(unclaimedRewards);
            }
        }
        require(
            depositToken.transferFrom(msg.sender, address(this), amount),
            "MasterChefStrategyV1::transfer failed"
        );
        _stakeDepositTokens(amount);
        uint256 depositFeeBP = _getDepositFee(PID);
        uint256 depositFee = amount.mul(depositFeeBP).div(_bip());
        _mint(account, getSharesForDepositTokens(amount.sub(depositFee)));
        totalDeposits = totalDeposits.add(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override {
        uint256 depositTokenAmount = getDepositTokensForShares(amount);
        if (depositTokenAmount > 0) {
            _withdrawDepositTokens(depositTokenAmount);
            uint256 withdrawFeeBP = _getWithdrawFee(PID);
            uint256 withdrawFee = depositTokenAmount.mul(withdrawFeeBP).div(
                _bip()
            );
            _safeTransfer(
                address(depositToken),
                msg.sender,
                depositTokenAmount.sub(withdrawFee)
            );
            _burn(msg.sender, amount);
            totalDeposits = totalDeposits.sub(depositTokenAmount);
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint256 amount) private {
        require(amount > 0, "MasterChefStrategyV1::_withdrawDepositTokens");
        _withdrawMasterchef(PID, amount);
    }

    function reinvest() external override onlyEOA {
        uint256 unclaimedRewards = checkReward();
        require(
            unclaimedRewards >= MIN_TOKENS_TO_REINVEST,
            "MasterChefStrategyV1::reinvest"
        );
        _reinvest(unclaimedRewards);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `MasterChef`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(uint256 amount) private {
        _getRewards(PID);

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(
            BIPS_DIVISOR
        );
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 depositTokenAmount = DexLibrary
            .convertRewardTokensToDepositTokens(
                amount.sub(devFee).sub(adminFee).sub(reinvestFee),
                address(rewardToken),
                address(depositToken),
                swapPairToken0,
                swapPairToken1
            );

        _stakeDepositTokens(depositTokenAmount);
        uint256 depositFeeBP = _getDepositFee(PID);
        uint256 depositFee = depositTokenAmount.mul(depositFeeBP).div(_bip());
        totalDeposits = totalDeposits.add(depositTokenAmount.sub(depositFee));

        emit Reinvest(totalDeposits, totalSupply);
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "MasterChefStrategyV1::_stakeDepositTokens");
        _depositMasterchef(PID, amount);
    }

    /**
     * @notice Safely transfer using an anonymosu ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(
            IERC20(token).transfer(to, value),
            "MasterChefStrategyV1::TRANSFER_FROM_FAILED"
        );
    }

    function checkReward() public view override returns (uint256) {
        uint256 pendingReward = _pendingRewards(PID, address(this));
        uint256 contractBalance = rewardToken.balanceOf(address(this));
        return pendingReward.add(contractBalance);
    }

    /**
     * @notice Estimate recoverable balance after withdraw fee
     * @return deposit tokens after withdraw fee
     */
    function estimateDeployedBalance()
        external
        view
        override
        returns (uint256)
    {
        (uint256 depositBalance, ) = _userInfo(PID, address(this));
        uint256 withdrawFeeBP = _getWithdrawFee(PID);
        uint256 withdrawFee = depositBalance.mul(withdrawFeeBP).div(_bip());
        return depositBalance.sub(withdrawFee);
    }

    function rescueDeployedFunds(
        uint256 minReturnAmountAccepted,
        bool disableDeposits
    ) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _emergencyWithdraw(PID);
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted,
            "MasterChefStrategyV1::rescueDeployedFunds"
        );
        totalDeposits = balanceAfter;
        emit Reinvest(totalDeposits, totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }

    /* VIRTUAL */

    function _depositMasterchef(uint256 _pid, uint256 _amount) internal virtual;

    function _withdrawMasterchef(uint256 _pid, uint256 _amount)
        internal
        virtual;

    function _emergencyWithdraw(uint256 _pid) internal virtual;

    function _getRewards(uint256 _pid) internal virtual;

    function _pendingRewards(uint256 _pid, address _user)
        internal
        view
        virtual
        returns (uint256);

    function _userInfo(uint256 pid, address user)
        internal
        view
        virtual
        returns (uint256 amount, uint256 rewardDebt);

    function _getDepositFee(uint256 pid)
        internal
        view
        virtual
        returns (uint256);

    function _getWithdrawFee(uint256 pid)
        internal
        view
        virtual
        returns (uint256);

    function _bip() internal view virtual returns (uint256);
}
