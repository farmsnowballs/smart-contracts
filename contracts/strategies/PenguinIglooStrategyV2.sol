// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategyV2.sol";
import "../interfaces/IPenguinIglooChef.sol";
import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";

/**
 * @notice Pool2 strategy for Penguin Igloos V2
 */
contract PenguinIglooStrategyV2 is YakStrategyV2 {
  using SafeMath for uint;
  IPenguinIglooChef public stakingContract;
  address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
  uint public PID;
  IPair private swapPairWAVAXPEFI;
    IPair private swapPairToken0;
    IPair private swapPairToken1;

  constructor(
    string memory _name,
    address _depositToken, 
    address _rewardToken,
    address _swapPairWAVAXPEFI,
        address _swapPairToken0,
        address _swapPairToken1, 
    address _stakingContract,
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
    stakingContract = IPenguinIglooChef(_stakingContract);
    PID = _pid;
    devAddr = msg.sender;
    setAllowances();
    stakingContract.setIpefiDistributionBips(0);
    setIpefiDistributionBips(0);
    assignSwapPairSafely(_swapPairWAVAXPEFI, _swapPairToken0, _swapPairToken1, _rewardToken);
    updateMinTokensToReinvest(_minTokensToReinvest);
    updateAdminFee(_adminFeeBips);
    updateDevFee(_devFeeBips);
    updateReinvestReward(_reinvestRewardBips);
    updateDepositsEnabled(true);
    //transferOwnership(_timelock);

    emit Reinvest(0, 0);
  }

  function totalDeposits() public override view returns (uint) {
        return stakingContract.userShares(PID,address(this));
    }

  function setIpefiDistributionBips(uint256 bips) public onlyOwner {
    stakingContract.setIpefiDistributionBips(bips);
  }

  /**
   * @notice Approve tokens for use in Strategy
   * @dev Restricted to avoid griefing attacks
   */
  function setAllowances() public override onlyOwner {
    depositToken.approve(address(stakingContract), MAX_UINT);
  }

      /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading reward tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken1
     */
    function assignSwapPairSafely(address _swapPairWAVAXPEFI, address _swapPairToken0, address _swapPairToken1, address _rewardToken) private {
        require(
            DexLibrary.checkSwapPairCompatibility(IPair(_swapPairWAVAXPEFI), address(WAVAX), address(_rewardToken)),
            "_swapPairWAVAXPEFI is not a WAVAX-Pefi pair"
        );
        require(
            _swapPairToken0 == address(0)
            || DexLibrary.checkSwapPairCompatibility(IPair(_swapPairToken0), address(WAVAX), IPair(address(depositToken)).token0()),
            "_swapPairToken0 is not a WAVAX+deposit token0"
        );
        require(
            _swapPairToken1 == address(0)
            || DexLibrary.checkSwapPairCompatibility(IPair(_swapPairToken1), address(WAVAX), IPair(address(depositToken)).token1()),
            "_swapPairToken0 is not a WAVAX+deposit token1"
        );
        // converts Pefi to WAVAX
        swapPairWAVAXPEFI = IPair(_swapPairWAVAXPEFI);
        // converts WAVAX to pair token0
        swapPairToken0 = IPair(_swapPairToken0);
        // converts WAVAX to pair token1
        swapPairToken1 = IPair(_swapPairToken1);
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
    require(DEPOSITS_ENABLED == true, "PenguinIglooStrategyV2::_deposit");
    if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
        uint unclaimedRewards = checkReward();
        if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
            _reinvest(unclaimedRewards);
        }
    }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "PenguinIglooStrategyV2::transfer failed");
    _stakeDepositTokens(amount);
    _mint(account, getSharesForDepositTokens(amount));
    emit Deposit(account, amount);
  }

  function withdraw(uint amount) external override {
    uint depositTokenAmount = getDepositTokensForShares(amount);
    if (depositTokenAmount > 0) {
      _withdrawDepositTokens(depositTokenAmount);
      (,,,,,, uint withdrawFeeBP,,) = stakingContract.poolInfo(PID);
      uint withdrawFee = depositTokenAmount.mul(withdrawFeeBP).div(BIPS_DIVISOR);
      _safeTransfer(address(depositToken), msg.sender, depositTokenAmount.sub(withdrawFee));
      _burn(msg.sender, amount);
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  function _withdrawDepositTokens(uint amount) private {
    require(amount > 0, "PenguinIglooStrategyV2::_withdrawDepositTokens");
    stakingContract.withdraw(PID, amount, address(this));
  }

  function reinvest() external override onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "PenguinIglooStrategyV2::reinvest");
    _reinvest(unclaimedRewards);
  }

  /**
    * @notice Reinvest rewards from staking contract to deposit tokens
    * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
    * @param unclaimedRewards deposit tokens to reinvest
    */
  function _reinvest(uint unclaimedRewards) private {
    stakingContract.harvest(PID, address(this));
    uint amount = _convertRewardIntoWAVAX(unclaimedRewards);
    uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(WAVAX), devAddr, devFee);
        }

        uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(WAVAX), owner(), adminFee);
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(WAVAX), msg.sender, reinvestFee);
        }

        uint depositTokenAmount = DexLibrary.convertRewardTokensToDepositTokens(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee),
            address(WAVAX),
            address(depositToken),
            swapPairToken0,
            swapPairToken1
        );
    _stakeDepositTokens(depositTokenAmount);
    emit Reinvest(totalDeposits(), totalSupply);
  }
    
  function _stakeDepositTokens(uint amount) private {
    require(amount > 0, "PenguinIglooStrategyV2::_stakeDepositTokens");
    stakingContract.deposit(PID, amount, address(this));
  }

  function checkReward() public override view returns (uint) {
    uint pendingReward = stakingContract.pendingPEFI(PID, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  function _convertRewardIntoWAVAX(uint pendingReward) private returns (uint) {
        return DexLibrary.swap(
            pendingReward,
            address(rewardToken), address(WAVAX),
            swapPairWAVAXPEFI
        );
    }

  /**
     * @notice Safely transfer using an anonymosu ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        require(IERC20(token).transfer(to, value), 'PenguinIglooStrategyV2::_safeTransfer');
    }

  /**
   * @notice Estimate recoverable balance after withdraw fee
   * @return deposit tokens after withdraw fee
   */
  function estimateDeployedBalance() external override view returns (uint) {
    (uint depositBalance, ) = stakingContract.userInfo(PID, address(this));
    (,,,,,, uint withdrawFeeBP,,) = stakingContract.poolInfo(PID);
    uint withdrawFee = depositBalance.mul(withdrawFeeBP).div(BIPS_DIVISOR);
    return depositBalance.sub(withdrawFee);
  }

  function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
    uint balanceBefore = depositToken.balanceOf(address(this));
    stakingContract.emergencyWithdraw(PID,address(this));
    uint balanceAfter = depositToken.balanceOf(address(this));
    require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "PenguinIglooStrategyV2::rescueDeployedFunds");
    emit Reinvest(totalDeposits(), totalSupply);
    if (DEPOSITS_ENABLED == true && disableDeposits == true) {
      updateDepositsEnabled(false);
    }
  }
}