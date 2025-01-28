// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../YakStrategyV2.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IWAVAX.sol";
import "../lib/DexLibrary.sol";
import "../lib/SafeERC20.sol";

/**
 * @notice VariableRewardsStrategy
 */
abstract contract SingleRewardStrategy is YakStrategyV2 {
    using SafeERC20 for IERC20;

    IWAVAX internal immutable WAVAX;
    address immutable rewardSwapPair;
    uint256 immutable swapFee;
    address immutable poolReward;

    struct SingleRewardStrategySettings {
        string name;
        address platformToken;
        address rewardSwapPair;
        uint256 swapFee;
        address timelock;
    }

    constructor(SingleRewardStrategySettings memory _settings, StrategySettings memory _strategySettings)
        YakStrategyV2(_strategySettings)
    {
        name = _settings.name;
        WAVAX = IWAVAX(_settings.platformToken);
        devAddr = 0x2D580F9CF2fB2D09BC411532988F2aFdA4E7BefF;
        rewardSwapPair = _settings.rewardSwapPair;
        swapFee = _settings.swapFee;
        address poolRewardToken;
        if (rewardSwapPair != address(0)) {
            address token0 = IPair(rewardSwapPair).token0();
            address token1 = IPair(rewardSwapPair).token1();
            poolRewardToken = token0 == _strategySettings.rewardToken ? token1 : token0;
        } else {
            require(_strategySettings.rewardToken == address(WAVAX), "SingleRewardStrategy::Invalid reward token");
            poolRewardToken = address(WAVAX);
        }
        poolReward = poolRewardToken;

        updateDepositsEnabled(true);
        transferOwnership(_settings.timelock);
        emit Reinvest(0, 0);
    }

    function calculateDepositFee(uint256 _amount) public view returns (uint256) {
        return _calculateDepositFee(_amount);
    }

    function calculateWithdrawFee(uint256 _amount) public view returns (uint256) {
        return _calculateWithdrawFee(_amount);
    }

    /**
     * @notice Deposit tokens to receive receipt tokens
     * @param _amount Amount of tokens to deposit
     */
    function deposit(uint256 _amount) external override {
        _deposit(msg.sender, _amount);
    }

    /**
     * @notice Deposit using Permit
     * @param _amount Amount of tokens to deposit
     * @param _deadline The time at which to expire the signature
     * @param _v The recovery byte of the signature
     * @param _r Half of the ECDSA signature pair
     * @param _s Half of the ECDSA signature pair
     */
    function depositWithPermit(
        uint256 _amount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external override {
        depositToken.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s);
        _deposit(msg.sender, _amount);
    }

    function depositFor(address _account, uint256 _amount) external override {
        _deposit(_account, _amount);
    }

    function _deposit(address _account, uint256 _amount) internal {
        require(DEPOSITS_ENABLED == true, "VariableRewardsStrategy::Deposits disabled");
        uint256 maxPendingRewards = MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST;
        if (maxPendingRewards > 0) {
            uint256 estimatedTotalReward = checkReward();
            if (estimatedTotalReward > maxPendingRewards) {
                _reinvest(true);
            }
        }
        require(
            depositToken.transferFrom(msg.sender, address(this), _amount),
            "VariableRewardsStrategy::Deposit token transfer failed"
        );
        uint256 depositFee = _calculateDepositFee(_amount);
        _mint(_account, getSharesForDepositTokens(_amount - depositFee));
        _stakeDepositTokens(_amount, depositFee);
        emit Deposit(_account, _amount);
    }

    /**
     * @notice Withdraw fee bips from underlying farm
     */
    function _getDepositFeeBips() internal view virtual returns (uint256) {
        return 0;
    }

    /**
     * @notice Calculate deposit fee of underlying farm
     * @dev Override if deposit fee is calculated dynamically
     */
    function _calculateDepositFee(uint256 _amount) internal view virtual returns (uint256) {
        uint256 depositFeeBips = _getDepositFeeBips();
        return (_amount * depositFeeBips) / _bip();
    }

    function withdraw(uint256 _amount) external override {
        uint256 depositTokenAmount = getDepositTokensForShares(_amount);
        require(depositTokenAmount > 0, "VariableRewardsStrategy::Withdraw amount too low");
        uint256 withdrawAmount = _withdrawFromStakingContract(depositTokenAmount);
        uint256 withdrawFee = _calculateWithdrawFee(depositTokenAmount);
        depositToken.safeTransfer(msg.sender, withdrawAmount - withdrawFee);
        _burn(msg.sender, _amount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    /**
     * @notice Withdraw fee bips from underlying farm
     * @dev Important: Do not override if withdraw fee is deducted from the amount returned by _withdrawFromStakingContract
     */
    function _getWithdrawFeeBips() internal view virtual returns (uint256) {
        return 0;
    }

    /**
     * @notice Calculate withdraw fee of underlying farm
     * @dev Override if withdraw fee is calculated dynamically
     * @dev Important: Do not override if withdraw fee is deducted from the amount returned by _withdrawFromStakingContract
     */
    function _calculateWithdrawFee(uint256 _amount) internal view virtual returns (uint256) {
        uint256 withdrawFeeBips = _getWithdrawFeeBips();
        return (_amount * withdrawFeeBips) / _bip();
    }

    function reinvest() external override onlyEOA {
        _reinvest(false);
    }

    function _convertPoolRewardsToRewardToken() private returns (uint256) {
        uint256 rewardTokenAmount = rewardToken.balanceOf(address(this));
        if (poolReward == address(WAVAX)) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                WAVAX.deposit{value: balance}();
            }
            if (address(rewardToken) == address(WAVAX)) {
                return rewardTokenAmount + balance;
            }
        }
        uint256 amount = IERC20(poolReward).balanceOf(address(this));
        if (amount > 0) {
            rewardTokenAmount += DexLibrary.swap(
                amount,
                poolReward,
                address(rewardToken),
                IPair(rewardSwapPair),
                swapFee
            );
        }
        return rewardTokenAmount;
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from the staking contract
     */
    function _reinvest(bool userDeposit) private {
        _getRewards();
        uint256 amount = _convertPoolRewardsToRewardToken();
        if (!userDeposit) {
            require(amount >= MIN_TOKENS_TO_REINVEST, "VariableRewardsStrategy::Reinvest amount too low");
        }

        uint256 devFee = (amount * DEV_FEE_BIPS) / BIPS_DIVISOR;
        if (devFee > 0) {
            rewardToken.safeTransfer(devAddr, devFee);
        }

        uint256 reinvestFee = (amount * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
        if (reinvestFee > 0) {
            rewardToken.safeTransfer(msg.sender, reinvestFee);
        }

        uint256 depositTokenAmount = _convertRewardTokenToDepositToken(amount - devFee - reinvestFee);

        uint256 depositFee = _calculateDepositFee(depositTokenAmount);
        _stakeDepositTokens(depositTokenAmount, depositFee);
        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _stakeDepositTokens(uint256 _amount, uint256 _depositFee) private {
        require(_amount > 0, "VariableRewardsStrategy::Stake amount too low");
        _depositToStakingContract(_amount, _depositFee);
    }

    function checkReward() public view override returns (uint256) {
        uint256 pendingReward = _pendingRewards();
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        if (poolReward == address(WAVAX)) {
            rewardTokenBalance += address(this).balance;
        }
        if (poolReward == address(rewardToken)) {
            return rewardTokenBalance += pendingReward;
        }
        uint256 poolRewardBalance = IERC20(poolReward).balanceOf(address(this));
        uint256 amount = poolRewardBalance + pendingReward;
        if (amount > 0) {
            return
                rewardTokenBalance +
                DexLibrary.estimateConversionThroughPair(
                    amount,
                    poolReward,
                    address(rewardToken),
                    IPair(rewardSwapPair),
                    swapFee
                );
        }
        return rewardTokenBalance;
    }

    /**
     * @notice Estimate recoverable balance after withdraw fee
     * @return deposit tokens after withdraw fee
     */
    function estimateDeployedBalance() external view override returns (uint256) {
        uint256 depositBalance = totalDeposits();
        uint256 withdrawFee = _calculateWithdrawFee(depositBalance);
        return depositBalance - withdrawFee;
    }

    function rescueDeployedFunds(
        uint256 _minReturnAmountAccepted,
        bool /*_disableDeposits*/
    ) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _emergencyWithdraw();
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter - balanceBefore >= _minReturnAmountAccepted,
            "VariableRewardsStrategy::Emergency withdraw minimum return amount not reached"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true) {
            updateDepositsEnabled(false);
        }
    }

    function _bip() internal view virtual returns (uint256) {
        return 10000;
    }

    /* VIRTUAL */
    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal virtual returns (uint256 toAmount);

    function _depositToStakingContract(uint256 _amount, uint256 _depositFee) internal virtual;

    function _withdrawFromStakingContract(uint256 _amount) internal virtual returns (uint256 withdrawAmount);

    function _emergencyWithdraw() internal virtual;

    function _getRewards() internal virtual;

    function _pendingRewards() internal view virtual returns (uint256);
}
