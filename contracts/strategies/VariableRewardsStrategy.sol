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
abstract contract VariableRewardsStrategy is YakStrategyV2 {
    using SafeERC20 for IERC20;

    IWAVAX internal immutable WAVAX;

    struct VariableRewardsStrategySettings {
        string name;
        address platformToken;
        RewardSwapPair[] rewardSwapPairs;
        address dev;
        address owner;
    }

    struct Reward {
        address reward;
        uint256 amount;
    }

    struct RewardSwapPair {
        address reward;
        address swapPair;
        uint256 swapFee;
    }

    // reward -> swapPair
    mapping(address => RewardSwapPair) public rewardSwapPairs;
    address[] public supportedRewards;
    uint256 public rewardCount;

    event AddReward(address rewardToken, address swapPair);
    event RemoveReward(address rewardToken);

    constructor(VariableRewardsStrategySettings memory _settings, StrategySettings memory _strategySettings)
        YakStrategyV2(_strategySettings)
    {
        name = _settings.name;
        WAVAX = IWAVAX(_settings.platformToken);

        for (uint256 i = 0; i < _settings.rewardSwapPairs.length; i++) {
            _addReward(
                _settings.rewardSwapPairs[i].reward,
                _settings.rewardSwapPairs[i].swapPair,
                _settings.rewardSwapPairs[i].swapFee
            );
        }

        updateDepositsEnabled(true);
        devAddr = _settings.dev;
        transferOwnership(_settings.owner);
        emit Reinvest(0, 0);
    }

    function addReward(address _rewardToken, address _swapPair) public onlyDev {
        _addReward(_rewardToken, _swapPair, DexLibrary.DEFAULT_SWAP_FEE);
    }

    function addReward(
        address _rewardToken,
        address _swapPair,
        uint256 _swapFee
    ) public onlyDev {
        _addReward(_rewardToken, _swapPair, _swapFee);
    }

    function _addReward(
        address _rewardToken,
        address _swapPair,
        uint256 _swapFee
    ) internal {
        if (_rewardToken != address(rewardToken)) {
            require(
                DexLibrary.checkSwapPairCompatibility(IPair(_swapPair), _rewardToken, address(rewardToken)),
                "VariableRewardsStrategy::Swap pair does not contain reward token"
            );
        }
        rewardSwapPairs[_rewardToken] = RewardSwapPair({reward: _rewardToken, swapPair: _swapPair, swapFee: _swapFee});
        supportedRewards.push(_rewardToken);
        rewardCount = rewardCount + 1;
        emit AddReward(_rewardToken, _swapPair);
    }

    function removeReward(address _rewardToken) public onlyDev {
        delete rewardSwapPairs[_rewardToken];
        bool found = false;
        for (uint256 i = 0; i < supportedRewards.length; i++) {
            if (_rewardToken == supportedRewards[i]) {
                found = true;
                supportedRewards[i] = supportedRewards[supportedRewards.length - 1];
            }
        }
        require(found, "VariableRewardsStrategy::Reward to delete not found!");
        supportedRewards.pop();
        rewardCount = rewardCount - 1;
        emit RemoveReward(_rewardToken);
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
        uint256 count = supportedRewards.length;
        for (uint256 i = 0; i < count; i++) {
            address reward = supportedRewards[i];
            if (reward == address(WAVAX)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    WAVAX.deposit{value: balance}();
                }
                if (address(rewardToken) == address(WAVAX)) {
                    rewardTokenAmount += balance;
                    continue;
                }
            }
            uint256 amount = IERC20(reward).balanceOf(address(this));
            if (amount > 0) {
                address swapPair = rewardSwapPairs[reward].swapPair;
                if (swapPair > address(0)) {
                    rewardTokenAmount += DexLibrary.swap(
                        amount,
                        reward,
                        address(rewardToken),
                        IPair(swapPair),
                        rewardSwapPairs[reward].swapFee
                    );
                }
            }
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
        Reward[] memory rewards = _pendingRewards();
        uint256 estimatedTotalReward = rewardToken.balanceOf(address(this));
        if (address(rewardToken) == address(WAVAX)) {
            estimatedTotalReward += address(this).balance;
        }
        for (uint256 i = 0; i < rewards.length; i++) {
            address reward = rewards[i].reward;
            if (reward == address(rewardToken)) {
                estimatedTotalReward += rewards[i].amount;
            } else if (reward > address(0)) {
                uint256 balance = IERC20(reward).balanceOf(address(this));
                uint256 amount = balance + rewards[i].amount;
                address swapPair = rewardSwapPairs[rewards[i].reward].swapPair;
                if (amount > 0 && swapPair > address(0)) {
                    estimatedTotalReward += DexLibrary.estimateConversionThroughPair(
                        amount,
                        reward,
                        address(rewardToken),
                        IPair(swapPair),
                        rewardSwapPairs[rewards[i].reward].swapFee
                    );
                }
            }
        }
        return estimatedTotalReward;
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

    function _pendingRewards() internal view virtual returns (Reward[] memory);
}
