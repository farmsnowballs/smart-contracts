// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategy.sol";
import "../interfaces/IStormChef.sol";
import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";

/**
 * @notice Strategy for Storm LP
 * @dev Referall fee is collected by devAddr on `deposit`
 */
contract StormStrategyForLP is YakStrategy {
  using SafeMath for uint;

  IStormChef public stakingContract;
  IPair private swapPairToken0;
  IPair private swapPairToken1;

  uint public PID;

  constructor(
    string memory _name,
    address _depositToken, 
    address _rewardToken, 
    address _stakingContract,
    address _swapPairToken0,
    address _swapPairToken1,
    address _timelock,
    uint _pid,
    uint _minTokensToReinvest,
    uint _adminFeeBips,
    uint _devFeeBips,
    uint _reinvestRewardBips
  ) {
    name = _name;
    depositToken = IPair(_depositToken);
    rewardToken = IERC20(_rewardToken);
    stakingContract = IStormChef(_stakingContract);
    PID = _pid;
    devAddr = msg.sender;

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
    function assignSwapPairSafely(address _swapPairToken0, address _swapPairToken1, address _rewardToken) private {
        if (_rewardToken != IPair(address(depositToken)).token0() && _rewardToken != IPair(address(depositToken)).token1()) {
            // deployment checks for non-pool2
            require(_swapPairToken0 > address(0), "Swap pair 0 is necessary but not supplied");
            require(_swapPairToken1 > address(0), "Swap pair 1 is necessary but not supplied");
            swapPairToken0 = IPair(_swapPairToken0);
            swapPairToken1 = IPair(_swapPairToken1);
            require(swapPairToken0.token0() == _rewardToken || swapPairToken0.token1() == _rewardToken, "Swap pair supplied does not have the reward token as one of it's pair");
            require(
                swapPairToken0.token0() == IPair(address(depositToken)).token0() || swapPairToken0.token1() == IPair(address(depositToken)).token0(),
                "Swap pair 0 supplied does not match the pair in question"
            );
            require(
                swapPairToken1.token0() == IPair(address(depositToken)).token1() || swapPairToken1.token1() == IPair(address(depositToken)).token1(),
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
    depositToken.approve(address(stakingContract), MAX_UINT);
  }

  /**
   * @notice Deposit tokens to receive receipt tokens
   * @param amount Amount of tokens to deposit
   */
  function deposit(uint amount) external override {
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
  function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external override {
    depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
    _deposit(msg.sender, amount);
  }

  function depositFor(address account, uint amount) external override {
      _deposit(account, amount);
  }

  function _deposit(address account, uint amount) internal {
    require(DEPOSITS_ENABLED == true, "StormStrategyForLP::_deposit");
    if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
        uint unclaimedRewards = checkReward();
        if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
            _reinvest(unclaimedRewards);
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
      (,,,, uint withdrawFeeBP, ) = stakingContract.poolInfo(PID);
      uint withdrawFee = depositTokenAmount.mul(withdrawFeeBP).div(BIPS_DIVISOR);
      _safeTransfer(address(depositToken), msg.sender, depositTokenAmount.sub(withdrawFee));
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits.sub(depositTokenAmount);
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  function _withdrawDepositTokens(uint amount) private {
    require(amount > 0, "StormStrategyForLP::_withdrawDepositTokens");
    stakingContract.withdraw(PID, amount);
  }

  function reinvest() external override onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "StormStrategyForLP::reinvest");
    _reinvest(unclaimedRewards);
  }

  /**
    * @notice Reinvest rewards from staking contract to deposit tokens
    * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
    * @param amount deposit tokens to reinvest
    */
  function _reinvest(uint amount) private {
    stakingContract.deposit(PID, 0, devAddr);

    uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
    if (devFee > 0) {
      _safeTransfer(address(rewardToken), devAddr, devFee);
    }

    uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
    if (adminFee > 0) {
      _safeTransfer(address(rewardToken), owner(), adminFee);
    }

    uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
    if (reinvestFee > 0) {
      _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
    }

    uint depositTokenAmount = DexLibrary.convertRewardTokensToDepositTokens(
      amount.sub(devFee).sub(adminFee).sub(reinvestFee),
      address(rewardToken),
      address(depositToken),
      swapPairToken0,
      swapPairToken1
    );

    _stakeDepositTokens(depositTokenAmount);
    totalDeposits = totalDeposits.add(depositTokenAmount);

    emit Reinvest(totalDeposits, totalSupply);
  }
    
  function _stakeDepositTokens(uint amount) private {
    require(amount > 0, "StormStrategyForLP::_stakeDepositTokens");
    stakingContract.deposit(PID, amount, devAddr);
  }

  /**
    * @notice Safely transfer using an anonymosu ERC20 token
    * @dev Requires token to return true on transfer
    * @param token address
    * @param to recipient address
    * @param value amount
    */
  function _safeTransfer(address token, address to, uint256 value) private {
    require(IERC20(token).transfer(to, value), 'StormStrategyForLP::TRANSFER_FROM_FAILED');
  }
  
  function checkReward() public override view returns (uint) {
    uint pendingReward = stakingContract.pendingStorm(PID, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  /**
   * @notice Estimate recoverable balance after withdraw fee
   * @return deposit tokens after withdraw fee
   */
  function estimateDeployedBalance() external override view returns (uint) {
    (uint depositBalance, ) = stakingContract.userInfo(PID, address(this));
    (,,,, uint withdrawFeeBP, ) = stakingContract.poolInfo(PID);
    uint withdrawFee = depositBalance.mul(withdrawFeeBP).div(BIPS_DIVISOR);
    return depositBalance.sub(withdrawFee);
  }

  function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
    uint balanceBefore = depositToken.balanceOf(address(this));
    stakingContract.emergencyWithdraw(PID);
    uint balanceAfter = depositToken.balanceOf(address(this));
    require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "StormStrategyForLP::rescueDeployedFunds");
    totalDeposits = balanceAfter;
    emit Reinvest(totalDeposits, totalSupply);
    if (DEPOSITS_ENABLED == true && disableDeposits == true) {
      updateDepositsEnabled(false);
    }
  }
}