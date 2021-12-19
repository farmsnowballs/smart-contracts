// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;
pragma experimental ABIEncoderV2;

import "./YakERC20.sol";
import "./lib/SafeMath.sol";
import "./interfaces/IOliveChef.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IERC20.sol";
import "./lib/Ownable.sol";

contract OliveStrategyForLPb is YakERC20, Ownable {
  using SafeMath for uint;

  uint public totalDeposits;

  IRouter public router;
  IPair public depositToken;
  IERC20 private token0;
  IERC20 private token1;
  IERC20 public rewardToken;
  IOliveChef public stakingContract;

  uint public PID;
  uint public MIN_TOKENS_TO_REINVEST = 20000;
  uint public REINVEST_REWARD_BIPS = 500;
  uint public ADMIN_FEE_BIPS = 500;
  uint constant private BIPS_DIVISOR = 10000;
  uint constant private UINT_MAX = uint256(-1);
  address constant private WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

  bool public REQUIRE_REINVEST_BEFORE_DEPOSIT;
  uint public MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT = 20;

  event Deposit(address indexed account, uint amount);
  event Withdraw(address indexed account, uint amount);
  event Reinvest(uint newTotalDeposits, uint newTotalSupply);
  event Recovered(address token, uint amount);
  event UpdateAdminFee(uint oldValue, uint newValue);
  event UpdateReinvestReward(uint oldValue, uint newValue);
  event UpdateMinTokensToReinvest(uint oldValue, uint newValue);
  event UpdateRequireReinvestBeforeDeposit(bool newValue);
  event UpdateMinTokensToReinvestBeforeDeposit(uint oldValue, uint newValue);

  constructor(
    address _depositToken, 
    address _rewardToken, 
    address _stakingContract,
    address _router,
    uint _pid
  ) {
    depositToken = IPair(_depositToken);
    rewardToken = IERC20(_rewardToken);
    stakingContract = IOliveChef(_stakingContract);
    router = IRouter(_router);

    PID = _pid;

    address _token0 = IPair(_depositToken).token0();
    address _token1 = IPair(_depositToken).token1();
    token0 = IERC20(_token0);
    token1 = IERC20(_token1);

    name = string(
      abi.encodePacked(
        "Yield Yak: ",
        depositToken.symbol(), " ",
        IERC20(_token0).symbol(), "-",
        IERC20(_token1).symbol()
      )
    );

    setAllowances();
    emit Reinvest(0, 0);
  }

  /**
    * @dev Throws if called by smart contract
    */
  modifier onlyEOA() {
      require(tx.origin == msg.sender, "onlyEOA");
      _;
  }

  /**
   * @notice Approve tokens for use in Strategy
   * @dev Restricted to avoid griefing attacks
   */
  function setAllowances() public onlyOwner {
    depositToken.approve(address(stakingContract), UINT_MAX);
    rewardToken.approve(address(router), UINT_MAX);
    token0.approve(address(router), UINT_MAX);
    token1.approve(address(router), UINT_MAX);
  }

  /**
    * @notice Revoke token allowance
    * @dev Restricted to avoid griefing attacks
    * @param token address
    * @param spender address
    */
  function revokeAllowance(address token, address spender) external onlyOwner {
    require(IERC20(token).approve(spender, 0));
  }

  /**
   * @notice Deposit tokens to receive receipt tokens
   * @param amount Amount of tokens to deposit
   */
  function deposit(uint amount) external {
    _deposit(amount);
  }

  /**
   * @notice Deposit using Permit
   * @param amount Amount of tokens to deposit
   * @param deadline The time at which to expire the signature
   * @param v The recovery byte of the signature
   * @param r Half of the ECDSA signature pair
   * @param s Half of the ECDSA signature pair
   */
  function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
    depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
    _deposit(amount);
  }

  function _deposit(uint amount) internal {
    require(totalDeposits >= totalSupply, "deposit failed");
    if (REQUIRE_REINVEST_BEFORE_DEPOSIT) {
      uint unclaimedRewards = checkReward();
      if (unclaimedRewards >= MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT) {
        _reinvest(unclaimedRewards);
      }
    }
    require(depositToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    _stakeDepositTokens(amount);
    _mint(msg.sender, getSharesForDepositTokens(amount));
    totalDeposits = totalDeposits.add(amount);
    emit Deposit(msg.sender, amount);
  }

  /**
   * @notice Withdraw LP tokens by redeeming receipt tokens
   * @param amount Amount of receipt tokens to redeem
   */
  function withdraw(uint amount) external {
    uint depositTokenAmount = getDepositTokensForShares(amount);
    if (depositTokenAmount > 0) {
      _withdrawDepositTokens(depositTokenAmount);
      require(depositToken.transfer(msg.sender, depositTokenAmount), "transfer failed");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits.sub(depositTokenAmount);
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  /**
   * @notice Calculate receipt tokens for a given amount of deposit tokens
   * @dev If contract is empty, use 1:1 ratio
   * @dev Could return zero shares for very low amounts of deposit tokens
   * @param amount deposit tokens
   * @return receipt tokens
   */
  function getSharesForDepositTokens(uint amount) public view returns (uint) {
    if (totalSupply.mul(totalDeposits) == 0) {
      return amount;
    }
    return amount.mul(totalSupply).div(totalDeposits);
  }

  /**
   * @notice Calculate deposit tokens for a given amount of receipt tokens
   * @param amount receipt tokens
   * @return deposit tokens
   */
  function getDepositTokensForShares(uint amount) public view returns (uint) {
    if (totalSupply.mul(totalDeposits) == 0) {
      return 0;
    }
    return amount.mul(totalDeposits).div(totalSupply);
  }

  /**
   * @notice Reward token balance that can be reinvested
   * @dev Staking rewards accurue to contract on each deposit/withdrawal
   * @return Unclaimed rewards, plus contract balance
   */
  function checkReward() public view returns (uint) {
    uint pendingReward = stakingContract.pendingOlive(PID, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  /**
   * @notice Estimate reinvest reward for caller
   * @return Estimated rewards tokens earned for calling `reinvest()`
   */
  function estimateReinvestReward() external view returns (uint) {
    uint unclaimedRewards = checkReward();
    if (unclaimedRewards >= MIN_TOKENS_TO_REINVEST) {
      return unclaimedRewards.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
    }
    return 0;
  }

  /**
   * @notice Reinvest rewards from staking contract to deposit tokens
   * @dev This external function requires minimum tokens to be met
   */
  function reinvest() external onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "MIN_TOKENS_TO_REINVEST");
    _reinvest(unclaimedRewards);
  }

  /**
   * @notice Reinvest rewards from staking contract to deposit tokens
   * @dev This internal function does not require mininmum tokens to be met
   */
  function _reinvest(uint amount) internal {
    stakingContract.deposit(PID, 0);

    uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
    if (adminFee > 0) {
      require(rewardToken.transfer(owner(), adminFee), "admin fee transfer failed");
    }

    uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
    if (reinvestFee > 0) {
      require(rewardToken.transfer(msg.sender, reinvestFee), "reinvest fee transfer failed");
    }

    uint lpTokenAmount = _convertRewardTokensToDepositTokens(amount.sub(adminFee).sub(reinvestFee));
    _stakeDepositTokens(lpTokenAmount);
    totalDeposits = totalDeposits.add(lpTokenAmount);

    emit Reinvest(totalDeposits, totalSupply);
  }

  /**
   * @notice Converts entire reward token balance to deposit tokens
   * @dev Always converts through router; there are no price checks enabled
   * @return deposit tokens received
   */
  function _convertRewardTokensToDepositTokens(uint amount) internal returns (uint) {
    uint amountIn = amount.div(2);
    require(amountIn > 0, "amount too low");

    // swap to token0
    address[] memory path0 = new address[](2);
    path0[0] = address(rewardToken);
    path0[1] = address(token0);

    uint amountOutToken0 = amountIn;
    if (path0[0] != path0[path0.length - 1]) {
      uint[] memory amountsOutToken0 = router.getAmountsOut(amountIn, path0);
      amountOutToken0 = amountsOutToken0[amountsOutToken0.length - 1];
      router.swapExactTokensForTokens(amountIn, amountOutToken0, path0, address(this), block.timestamp);
    }

    // swap to token1
    address[] memory path1 = new address[](3);
    path1[0] = path0[0];
    path1[1] = WAVAX;
    path1[2] = address(token1);

    uint amountOutToken1 = amountIn;
    if (path1[0] != path1[path1.length - 1]) {
      uint[] memory amountsOutToken1 = router.getAmountsOut(amountIn, path1);
      amountOutToken1 = amountsOutToken1[amountsOutToken1.length - 1];
      router.swapExactTokensForTokens(amountIn, amountOutToken1, path1, address(this), block.timestamp);
    }

    (,,uint liquidity) = router.addLiquidity(
      path0[path0.length - 1], path1[path1.length - 1],
      amountOutToken0, amountOutToken1,
      0, 0,
      address(this),
      block.timestamp
    );

    return liquidity;
  }

  /**
   * @notice Stakes deposit tokens in Staking Contract
   * @param amount deposit tokens to stake
   */
  function _stakeDepositTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.deposit(PID, amount);
  }

  /**
   * @notice Withdraws deposit tokens from Staking Contract
   * @dev Reward tokens are automatically collected
   * @dev Reward tokens are not automatically reinvested
   * @param amount deposit tokens to remove
   */
  function _withdrawDepositTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.withdraw(PID, amount);
  }

  /**
   * @notice Allows exit from Staking Contract without additional logic
   * @dev Reward tokens are not automatically collected
   * @dev New deposits will be effectively disabled
   */
  function emergencyWithdraw() external onlyOwner {
    stakingContract.emergencyWithdraw(PID);
    totalDeposits = 0;
  }

  /**
   * @notice Update reinvest minimum threshold for external callers
   * @param newValue min threshold in wei
   */
  function updateMinTokensToReinvest(uint newValue) external onlyOwner {
    emit UpdateMinTokensToReinvest(MIN_TOKENS_TO_REINVEST, newValue);
    MIN_TOKENS_TO_REINVEST = newValue;
  }

  /**
   * @notice Update admin fee
   * @dev Total fees cannot be greater than BIPS_DIVISOR (100%)
   * @param newValue specified in BIPS
   */
  function updateAdminFee(uint newValue) external onlyOwner {
    require(newValue.add(REINVEST_REWARD_BIPS) <= BIPS_DIVISOR, "admin fee too high");
    emit UpdateAdminFee(ADMIN_FEE_BIPS, newValue);
    ADMIN_FEE_BIPS = newValue;
  }

  /**
   * @notice Update reinvest reward
   * @dev Total fees cannot be greater than BIPS_DIVISOR (100%)
   * @param newValue specified in BIPS
   */
  function updateReinvestReward(uint newValue) external onlyOwner {
    require(newValue.add(ADMIN_FEE_BIPS) <= BIPS_DIVISOR, "reinvest reward too high");
    emit UpdateReinvestReward(REINVEST_REWARD_BIPS, newValue);
    REINVEST_REWARD_BIPS = newValue;
  }

  /**
   * @notice Toggle requirement to reinvest before deposit
   */
  function updateRequireReinvestBeforeDeposit() external onlyOwner {
    REQUIRE_REINVEST_BEFORE_DEPOSIT = !REQUIRE_REINVEST_BEFORE_DEPOSIT;
    emit UpdateRequireReinvestBeforeDeposit(REQUIRE_REINVEST_BEFORE_DEPOSIT);
  }

  /**
   * @notice Update reinvest minimum threshold before a deposit
   * @param newValue min threshold in wei
   */
  function updateMinTokensToReinvestBeforeDeposit(uint newValue) external onlyOwner {
    emit UpdateMinTokensToReinvestBeforeDeposit(MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT, newValue);
    MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT = newValue;
  }

  /**
   * @notice Recover ERC20 from contract
   * @param tokenAddress token address
   * @param tokenAmount amount to recover
   */
  function recoverERC20(address tokenAddress, uint tokenAmount) external onlyOwner {
    require(tokenAmount > 0, 'amount too low');
    require(tokenAddress != address(depositToken), "cannot recover deposit token");
    IERC20(tokenAddress).transfer(msg.sender, tokenAmount);
    emit Recovered(tokenAddress, tokenAmount);
  }

  /**
   * @notice Recover AVAX from contract
   * @param amount amount
   */
  function recoverAVAX(uint amount) external onlyOwner {
    require(amount > 0, 'amount too low');
    msg.sender.transfer(amount);
    emit Recovered(address(0), amount);
  }
}