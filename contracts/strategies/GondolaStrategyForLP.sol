// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategy.sol";
import "../interfaces/IGondolaChef.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IPair.sol";

/**
 * @notice Pool2 strategy for Gondola Farms
 */
contract GondolaStrategyForLP is YakStrategy {
  using SafeMath for uint;

  IRouter public router;
  IGondolaChef public stakingContract;

  uint public PID;

  constructor(
    string memory _name,
    address _depositToken, 
    address _rewardToken, 
    address _stakingContract,
    address _router,
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
    stakingContract = IGondolaChef(_stakingContract);
    router = IRouter(_router);
    PID = _pid;
    devAddr = msg.sender;

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
   * @notice Approve tokens for use in Strategy
   * @dev Restricted to avoid griefing attacks
   */
  function setAllowances() public override onlyOwner {
    depositToken.approve(address(stakingContract), MAX_UINT);
    rewardToken.approve(address(router), MAX_UINT);
    IERC20(IPair(address(depositToken)).token0()).approve(address(router), MAX_UINT);
    IERC20(IPair(address(depositToken)).token1()).approve(address(router), MAX_UINT);
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
    require(DEPOSITS_ENABLED == true, "GondolaStrategyForLP::_deposit");
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
      require(depositToken.transfer(msg.sender, depositTokenAmount), "GondolaStrategyForLP::withdraw");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits.sub(depositTokenAmount);
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  function _withdrawDepositTokens(uint amount) private {
    require(amount > 0, "GondolaStrategyForLP::_withdrawDepositTokens");
    stakingContract.withdraw(PID, amount);
  }

  function reinvest() external override onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "GondolaStrategyForLP::reinvest");
    _reinvest(unclaimedRewards);
  }

  /**
    * @notice Reinvest rewards from staking contract to deposit tokens
    * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
    * @param amount deposit tokens to reinvest
    */
  function _reinvest(uint amount) private {
    stakingContract.deposit(PID, 0);

    uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
    if (devFee > 0) {
      require(rewardToken.transfer(devAddr, devFee), "GondolaStrategyForLP::_reinvest, dev");
    }

    uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
    if (adminFee > 0) {
      require(rewardToken.transfer(owner(), adminFee), "GondolaStrategyForLP::_reinvest, admin");
    }

    uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
    if (reinvestFee > 0) {
      require(rewardToken.transfer(msg.sender, reinvestFee), "GondolaStrategyForLP::_reinvest, reward");
    }

    uint depositTokenAmount = _convertRewardTokensToDepositTokens(
      amount.sub(devFee).sub(adminFee).sub(reinvestFee)
    );

    _stakeDepositTokens(depositTokenAmount);
    totalDeposits = totalDeposits.add(depositTokenAmount);

    emit Reinvest(totalDeposits, totalSupply);
  }
    
  function _stakeDepositTokens(uint amount) private {
    require(amount > 0, "GondolaStrategyForLP::_stakeDepositTokens");
    stakingContract.deposit(PID, amount);
  }

  function checkReward() public override view returns (uint) {
    uint pendingReward = stakingContract.pendingGondola(PID, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  /**
    * @notice Converts reward tokens to deposit tokens
    * @dev Always converts through router; there are no price checks enabled
    * @return deposit tokens received
    */
  function _convertRewardTokensToDepositTokens(uint amount) private returns (uint) {
    uint amountIn = amount.div(2);
    require(amountIn > 0, "GondolaStrategyForLP::_convertRewardTokensToDepositTokens");

    // swap to token0
    uint path0Length = 2;
    address[] memory path0 = new address[](path0Length);
    path0[0] = address(rewardToken);
    path0[1] = IPair(address(depositToken)).token0();

    uint amountOutToken0 = amountIn;
    if (path0[0] != path0[path0Length - 1]) {
      uint[] memory amountsOutToken0 = router.getAmountsOut(amountIn, path0);
      amountOutToken0 = amountsOutToken0[amountsOutToken0.length - 1];
      router.swapExactTokensForTokens(amountIn, amountOutToken0, path0, address(this), block.timestamp);
    }

    // swap to token1
    uint path1Length = 2;
    address[] memory path1 = new address[](path1Length);
    path1[0] = path0[0];
    path1[1] = IPair(address(depositToken)).token1();

    uint amountOutToken1 = amountIn;
    if (path1[0] != path1[path1Length - 1]) {
      uint[] memory amountsOutToken1 = router.getAmountsOut(amountIn, path1);
      amountOutToken1 = amountsOutToken1[amountsOutToken1.length - 1];
      router.swapExactTokensForTokens(amountIn, amountOutToken1, path1, address(this), block.timestamp);
    }

    (,,uint liquidity) = router.addLiquidity(
      path0[path0Length - 1], path1[path1Length - 1],
      amountOutToken0, amountOutToken1,
      0, 0,
      address(this),
      block.timestamp
    );

    return liquidity;
  }

  /**
   * @notice Estimate recoverable balance
   * @return deposit tokens
   */
  function estimateDeployedBalance() external override view returns (uint) {
    (uint depositBalance, ) = stakingContract.userInfo(PID, address(this));
    return depositBalance;
  }

  function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
    uint balanceBefore = depositToken.balanceOf(address(this));
    stakingContract.emergencyWithdraw(PID);
    uint balanceAfter = depositToken.balanceOf(address(this));
    require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "GondolaStrategyForLP::rescueDeployedFunds");
    totalDeposits = balanceAfter;
    emit Reinvest(totalDeposits, totalSupply);
    if (DEPOSITS_ENABLED == true && disableDeposits == true) {
      updateDepositsEnabled(false);
    }
  }
}