// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategy.sol";
import "../interfaces/IBenqiStakingContract.sol";
import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";

/**
 * @notice Benqi strategy for staking QI-AVAX.
 */
contract BenqiStrategyForLP is YakStrategy {
    using SafeMath for uint;

    IBenqiStakingContract private stakingContract;
    IERC20 private wavaxRewardToken;
    IERC20 private qiRewardToken;
    IPair private swapPairToken; // WAVAX-QI LP
    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);

    constructor (
        string memory _name,
        address _depositToken,
        address _qiRewardToken,
        address _stakingContract,
        address _swapPairToken,
        address _timelock,
        uint _minTokensToReinvest,
        uint _adminFeeBips,
        uint _devFeeBips,
        uint _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        wavaxRewardToken = IERC20(address(WAVAX));
        rewardToken = wavaxRewardToken;
        qiRewardToken = IERC20(_qiRewardToken);
        stakingContract = IBenqiStakingContract(_stakingContract);
        devAddr = msg.sender;

        assignSwapPairSafely(_swapPairToken);
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
     * @dev Checks that selected Pairs are valid for trading deposit tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken
     */
    function assignSwapPairSafely(address _swapPairToken) private {
        require(_swapPairToken > address(0), "Swap pair is necessary but not supplied");
        swapPairToken = IPair(_swapPairToken);
        require(isPairEquals(swapPairToken, wavaxRewardToken, qiRewardToken)
            || isPairEquals(swapPairToken, qiRewardToken, wavaxRewardToken),
            "Swap pair does not match WAVAX or QI.");
    }

    function isPairEquals(IPair pair, IERC20 left, IERC20 right) private returns (bool) {
        return pair.token0() == address(left) && pair.token1() == address(right);
    }

    function setAllowances() public override onlyOwner {
        depositToken.approve(address(stakingContract), MAX_UINT);
    }

    function deposit(uint amount) external override {
        _deposit(msg.sender, amount);
    }

    function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external override {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint amount) external override {
        _deposit(account, amount);
    }

    function _deposit(address account, uint amount) private onlyAllowedDeposits {
        require(DEPOSITS_ENABLED == true, "BenqiStrategyForLP::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            (uint avaxAmount, uint qiAmount, uint totalAvaxAmount) = _checkRewards();
            if (totalAvaxAmount > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(avaxAmount, qiAmount);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount));
        _stakeDepositTokens(amount);
        _mint(account, getSharesForDepositTokens(amount));
        totalDeposits = totalDeposits.add(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint amount) external override {
        uint depositTokenAmount = getDepositTokensForShares(amount);
        if (depositTokenAmount > 0) {
            _withdrawDepositTokens(depositTokenAmount);
            _safeTransfer(address(depositToken), msg.sender, depositTokenAmount);
            _burn(msg.sender, amount);
            totalDeposits = totalDeposits.sub(depositTokenAmount);
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint amount) private {
        require(amount > 0, "BenqiStrategyForLP::_withdrawDepositTokens");
        stakingContract.redeem(amount);
    }

    receive() external payable {
        require(
            msg.sender == address(WAVAX) ||
            msg.sender == address(stakingContract),
            "BenqiStrategyForLP::payments not allowed"
        );
    }

    function reinvest() external override onlyEOA {
        (uint avaxAmount, uint qiAmount, uint totalAvaxAmount) = _checkRewards();
        require(totalAvaxAmount >= MIN_TOKENS_TO_REINVEST, "BenqiStrategyForLP::reinvest");
        _reinvest(avaxAmount, qiAmount);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param avaxAmount amount of WAVAX token to reinvest
     * @param qiAmount amount of QI token to reinvest
     */
    function _reinvest(uint avaxAmount, uint qiAmount) private {
        stakingContract.claimRewards();
        // wrap avax reward to wavax.
        if (avaxAmount > 0) {
            WAVAX.deposit{value: avaxAmount}();
        }
        uint amount = _reinvestToken(wavaxRewardToken, avaxAmount) + _reinvestToken(qiRewardToken, qiAmount);
        _stakeDepositTokens(amount);
        totalDeposits = totalDeposits.add(amount);
        emit Reinvest(totalDeposits, totalSupply);
    }

    function _reinvestToken(IERC20 token, uint amount) private returns (uint depositTokenAmount) {
        uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(token), devAddr, devFee);
        }

        uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(token), owner(), adminFee);
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(token), msg.sender, reinvestFee);
        }

        depositTokenAmount = DexLibrary.convertRewardTokensToDepositTokens(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee),
            address(token),
            address(depositToken),
            swapPairToken,
            swapPairToken
        );
    }
    
    function _stakeDepositTokens(uint amount) private {
        require(amount > 0, "BenqiStrategyForLP::_stakeDepositTokens");
        stakingContract.deposit(amount);
    }

    /**
     * @notice Safely transfer using an anonymous ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        require(IERC20(token).transfer(to, value), 'BenqiStrategyForLP::TRANSFER_FROM_FAILED');
    }

    function _checkRewards() internal view returns (uint avaxAmount, uint qiAmount, uint totalAvaxAmount) {
        uint avaxRewards = stakingContract.getClaimableRewards(0);
        uint qiRewards = stakingContract.getClaimableRewards(1);

        uint qiAsWavax = DexLibrary.estimateConversionThroughPair(
            qiRewards, address(qiRewardToken),
            address(wavaxRewardToken), swapPairToken
        );
        return (avaxAmount, qiAmount, avaxRewards.add(qiAsWavax));
    }

    function checkReward() public override view returns (uint) {
        (,,uint avaxRewards) = _checkRewards();
        return avaxRewards;
    }

    function estimateDeployedBalance() external override view returns (uint) {
        return stakingContract.supplyAmount(address(this));
    }

    function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint balanceBefore = stakingContract.supplyAmount(address(this));
        stakingContract.redeem(balanceBefore);
        uint balanceAfter = stakingContract.supplyAmount(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "BenqiStrategyForLP::rescueDeployedFunds");
        totalDeposits = balanceAfter;
        emit Reinvest(totalDeposits, totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}