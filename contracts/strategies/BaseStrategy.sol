// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../YakStrategyV3.sol";
import "../interfaces/IWGAS.sol";
import "../lib/SafeERC20.sol";
import "./../interfaces/ISimpleRouter.sol";

/**
 * @notice BaseStrategy
 */
abstract contract BaseStrategy is YakStrategyV3 {
    using SafeERC20 for IERC20;

    IWGAS internal immutable WGAS;

    struct BaseStrategySettings {
        address gasToken;
        address[] rewards;
        address simpleRouter;
    }

    struct Reward {
        address reward;
        uint256 amount;
    }

    address[] public supportedRewards;
    ISimpleRouter public simpleRouter;

    event AddReward(address rewardToken);
    event RemoveReward(address rewardToken);
    event UpdateRouter(address oldRouter, address newRouter);

    constructor(BaseStrategySettings memory _settings, StrategySettings memory _strategySettings)
        YakStrategyV3(_strategySettings)
    {
        WGAS = IWGAS(_settings.gasToken);

        supportedRewards = _settings.rewards;

        simpleRouter = ISimpleRouter(_settings.simpleRouter);

        emit Reinvest(0, 0);
    }

    function updateRouter(address _router) public onlyDev {
        emit UpdateRouter(address(simpleRouter), _router);
        simpleRouter = ISimpleRouter(_router);
    }

    function addReward(address _rewardToken) public onlyDev {
        bool found;
        for (uint256 i = 0; i < supportedRewards.length; i++) {
            if (_rewardToken == supportedRewards[i]) {
                found = true;
            }
        }
        require(!found, "BaseStrategy::Reward already configured!");
        supportedRewards.push(_rewardToken);
        emit AddReward(_rewardToken);
    }

    function removeReward(address _rewardToken) public onlyDev {
        bool found;
        for (uint256 i = 0; i < supportedRewards.length; i++) {
            if (_rewardToken == supportedRewards[i]) {
                found = true;
                supportedRewards[i] = supportedRewards[supportedRewards.length - 1];
            }
        }
        require(found, "BaseStrategy::Reward not configured!");
        supportedRewards.pop();
        emit RemoveReward(_rewardToken);
    }

    function getSupportedRewardsLength() public view returns (uint256) {
        return supportedRewards.length;
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
    function depositWithPermit(uint256 _amount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        override
    {
        depositToken.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s);
        _deposit(msg.sender, _amount);
    }

    function depositFor(address _account, uint256 _amount) external override {
        _deposit(_account, _amount);
    }

    function _deposit(address _account, uint256 _amount) internal {
        require(DEPOSITS_ENABLED == true, "BaseStrategy::Deposits disabled");
        beforeDeposit();
        _reinvest(true);
        require(
            depositToken.transferFrom(msg.sender, address(this), _amount), "BaseStrategy::Deposit token transfer failed"
        );
        uint256 depositFee = _calculateDepositFee(_amount);
        _mint(_account, getSharesForDepositTokens(_amount - depositFee));
        _stakeDepositTokens(_amount, depositFee);
        emit Deposit(_account, _amount);
    }

    function beforeDeposit() internal virtual {}

    /**
     * @notice Deposit fee bips from underlying farm
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
        beforeWithdraw();
        uint256 depositTokenAmount = getDepositTokensForShares(_amount);
        require(depositTokenAmount > 0, "BaseStrategy::Withdraw amount too low");
        uint256 withdrawAmount = _withdrawFromStakingContract(depositTokenAmount);
        uint256 withdrawFee = _calculateWithdrawFee(depositTokenAmount);
        depositToken.safeTransfer(msg.sender, withdrawAmount - withdrawFee);
        _burn(msg.sender, _amount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    function beforeWithdraw() internal virtual {}

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
        _getRewards();
        uint256 rewardTokenAmount = rewardToken.balanceOf(address(this));
        uint256 count = supportedRewards.length;
        for (uint256 i = 0; i < count; i++) {
            address reward = supportedRewards[i];
            if (reward == address(WGAS)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    WGAS.deposit{value: balance}();
                }
                if (address(rewardToken) == address(WGAS)) {
                    rewardTokenAmount += balance;
                    continue;
                }
            }
            uint256 amount = IERC20(reward).balanceOf(address(this));
            if (amount > 0 && reward != address(rewardToken)) {
                FormattedOffer memory offer = simpleRouter.query(amount, reward, address(rewardToken));
                rewardTokenAmount += _swap(offer);
            }
        }
        return rewardTokenAmount;
    }

    /**
     * @notice Reinvest rewards from staking contract
     * @param userDeposit Controls whether or not a gas refund is payed to msg.sender
     */
    function _reinvest(bool userDeposit) private {
        uint256 amount = _convertPoolRewardsToRewardToken();
        if (amount > MIN_TOKENS_TO_REINVEST) {
            uint256 devFee = (amount * DEV_FEE_BIPS) / BIPS_DIVISOR;
            if (devFee > 0) {
                rewardToken.safeTransfer(feeCollector, devFee);
            }

            uint256 reinvestFee = userDeposit ? 0 : (amount * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
            if (reinvestFee > 0) {
                rewardToken.safeTransfer(msg.sender, reinvestFee);
            }

            uint256 depositTokenAmount = _convertRewardTokenToDepositToken(amount - devFee - reinvestFee);

            if (depositTokenAmount > 0) {
                uint256 depositFee = _calculateDepositFee(depositTokenAmount);
                _stakeDepositTokens(depositTokenAmount, depositFee);
            }
        }
        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal virtual returns (uint256 toAmount) {
        if (address(rewardToken) == address(depositToken)) return _fromAmount;
        FormattedOffer memory offer = simpleRouter.query(_fromAmount, address(rewardToken), address(depositToken));
        return _swap(offer);
    }

    function _stakeDepositTokens(uint256 _amount, uint256 _depositFee) private {
        require(_amount > 0, "BaseStrategy::Stake amount too low");
        _depositToStakingContract(_amount, _depositFee);
    }

    function _swap(FormattedOffer memory _offer) internal returns (uint256 amountOut) {
        if (_offer.amounts.length > 0 && _offer.amounts[_offer.amounts.length - 1] > 0) {
            IERC20(_offer.path[0]).approve(address(simpleRouter), _offer.amounts[0]);
            return simpleRouter.swap(_offer);
        }
        return 0;
    }

    function checkReward() public view override returns (uint256) {
        Reward[] memory rewards = _pendingRewards();
        uint256 estimatedTotalReward = rewardToken.balanceOf(address(this));
        for (uint256 i = 0; i < rewards.length; i++) {
            address reward = rewards[i].reward;
            if (reward == address(WGAS)) {
                rewards[i].amount += address(this).balance;
            }
            if (reward == address(rewardToken)) {
                estimatedTotalReward += rewards[i].amount;
            } else if (reward > address(0)) {
                uint256 balance = IERC20(reward).balanceOf(address(this));
                uint256 amount = balance + rewards[i].amount;
                if (amount > 0) {
                    FormattedOffer memory offer = simpleRouter.query(amount, reward, address(rewardToken));
                    estimatedTotalReward += offer.amounts.length > 1 ? offer.amounts[offer.amounts.length - 1] : 0;
                }
            }
        }
        return estimatedTotalReward;
    }

    function rescueDeployedFunds(uint256 _minReturnAmountAccepted) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _emergencyWithdraw();
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter - balanceBefore >= _minReturnAmountAccepted,
            "BaseStrategy::Emergency withdraw minimum return amount not reached"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true) {
            disableDeposits();
        }
    }

    function _bip() internal view virtual returns (uint256) {
        return 10000;
    }

    /* ABSTRACT */
    function _depositToStakingContract(uint256 _amount, uint256 _depositFee) internal virtual;

    function _withdrawFromStakingContract(uint256 _amount) internal virtual returns (uint256 withdrawAmount);

    function _emergencyWithdraw() internal virtual;

    function _getRewards() internal virtual;

    function _pendingRewards() internal view virtual returns (Reward[] memory);
}
