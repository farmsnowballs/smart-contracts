// // SPDX-License-Identifier: MIT
// pragma solidity ^0.7.0;

// import "../YakStrategy.sol";
// import "../interfaces/ICurveStableSwapAave.sol";
// import "../interfaces/ICurveRewardsGauge.sol";
// import "../interfaces/IPair.sol";
// import "../lib/DexLibrary.sol";
// import "hardhat/console.sol";

// /**
//  * @notice Pool2 strategy for StakingRewards
//  */
// contract CurveStrategyV1 is YakStrategy {
//     using SafeMath for uint;

//     ICurveStableSwapAave public stakingContract;
//     ICurveRewardsGauge public gaugeContract;
//     IPair private swapPair;
//     bytes private constant zeroBytes = new bytes(0);
//     address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
//     address private constant AV3CRV = 0x1337BedC9D22ecbe766dF105c9623922A27963EC;

//     constructor (
//         string memory _name,
//         address _depositToken,
//         address _stakingContract,
//         address _gaugeContract,
//         address _swapPair,
//         address _timelock,
//         uint _minTokensToReinvest,
//         uint _adminFeeBips,
//         uint _devFeeBips,
//         uint _reinvestRewardBips
//     ) {
//         name = _name;
//         depositToken = IERC20(_depositToken);
//         rewardToken = IERC20(WAVAX);
//         swapPair = IPair(_swapPair);
//         stakingContract = ICurveStableSwapAave(_stakingContract);
//         gaugeContract = ICurveRewardsGauge(_gaugeContract);
//         devAddr = msg.sender;

//         //assignSwapPairSafely(_swapPairToken0, WAVAX);
//         setAllowances();
//         updateMinTokensToReinvest(_minTokensToReinvest);
//         updateAdminFee(_adminFeeBips);
//         updateDevFee(_devFeeBips);
//         updateReinvestReward(_reinvestRewardBips);
//         updateDepositsEnabled(true);
//         transferOwnership(_timelock);

//         emit Reinvest(0, 0);
//     }

//     /**
//      * @notice Initialization helper for Pair deposit tokens
//      * @dev Checks that selected Pairs are valid for trading reward tokens
//      * @dev Assigns values to swapPairToken0 and swapPairToken1
//      */
//     // function assignSwapPairSafely(address _swapPairToken0, address _rewardToken) private {
//     //     if (_rewardToken != IPair(address(depositToken)).token0() && _rewardToken != IPair(address(depositToken)).token1()) {
//     //         // deployment checks for non-pool2
//     //         require(_swapPairToken0 > address(0), "Swap pair 0 is necessary but not supplied");
//     //         swapPairToken0 = IPair(_swapPairToken0);
//     //         require(swapPairToken0.token0() == _rewardToken || swapPairToken0.token1() == _rewardToken, "Swap pair supplied does not have the reward token as one of it's pair");
//     //         require(
//     //             swapPairToken0.token0() == IPair(address(depositToken)).token0() || swapPairToken0.token1() == IPair(address(depositToken)).token0(),
//     //             "Swap pair 0 supplied does not match the pair in question"
//     //         );
//     //     } else if (_rewardToken == IPair(address(depositToken)).token1()) {
//     //         swapPairToken0 = IPair(address(depositToken));
//     //     }
//     // }

//     function setAllowances() public override onlyOwner {
//         depositToken.approve(address(stakingContract), MAX_UINT);
//         depositToken.approve(address(gaugeContract), MAX_UINT);
//         IERC20(AV3CRV).approve(address(gaugeContract), type(uint256).max);
//     }

//     function deposit(uint amount) external override {
//         _deposit(msg.sender, amount);
//     }

//     function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external override {
//         depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
//         _deposit(msg.sender, amount);
//     }

//     function depositFor(address account, uint amount) external override {
//         _deposit(account, amount);
//     }

//     function _deposit(address account, uint amount) private onlyAllowedDeposits {
//         require(DEPOSITS_ENABLED == true, "DexStrategyV6::_deposit");
//         if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
//             uint unclaimedRewards = checkReward();
//             if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
//                 _reinvest(unclaimedRewards);
//             }
//         }
//         console.log("deposit transfer start");
//         require(depositToken.transferFrom(msg.sender, address(this), amount));
//         _stakeDepositTokens(amount);
//         _mint(account, getSharesForDepositTokens(amount));
//         totalDeposits = totalDeposits.add(amount);
//         emit Deposit(account, amount);
//     }

//     function withdraw(uint amount) external override {
//         uint depositTokenAmount = getDepositTokensForShares(amount);
//         if (depositTokenAmount > 0) {
//             _withdrawDepositTokens(depositTokenAmount);
//             _safeTransfer(address(depositToken), msg.sender, depositTokenAmount);
//             _burn(msg.sender, amount);
//             totalDeposits = totalDeposits.sub(depositTokenAmount);
//             emit Withdraw(msg.sender, depositTokenAmount);
//         }
//     }

//     function _withdrawDepositTokens(uint amount) private {
//         require(amount > 0, "DexStrategyV6::_withdrawDepositTokens");
//         gaugeContract.withdraw(expectedAmount.sub(slippage));
//     }

//     function reinvest() external override onlyEOA {
//         uint unclaimedRewards = checkReward();
//         require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "DexStrategyV6::reinvest");
//         _reinvest(unclaimedRewards);
//     }

//     /**
//      * @notice Reinvest rewards from staking contract to deposit tokens
//      * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
//      * @param amount deposit tokens to reinvest
//      */
//     function _reinvest(uint amount) private {
//         //stakingContract.getReward();

//         uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
//         if (devFee > 0) {
//             _safeTransfer(address(rewardToken), devAddr, devFee);
//         }

//         uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
//         if (adminFee > 0) {
//             _safeTransfer(address(rewardToken), owner(), adminFee);
//         }

//         uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
//         if (reinvestFee > 0) {
//             _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
//         }

//         // uint depositTokenAmount = DexLibrary.convertRewardTokensToDepositTokens(
//         //     amount.sub(devFee).sub(adminFee).sub(reinvestFee),
//         //     address(rewardToken),
//         //     address(depositToken),
//         //     swapPairToken0,
//         //     address(0x0)
//         // );

//         // _stakeDepositTokens(depositTokenAmount);
//         // totalDeposits = totalDeposits.add(depositTokenAmount);

//         emit Reinvest(totalDeposits, totalSupply);
//     }
    
//     function _stakeDepositTokens(uint amount) private {
//         require(amount > 0, "DexStrategyV6::_stakeDepositTokens");
//         console.log("Amount: %s", amount);
//         uint expectedAmount = stakingContract.calc_token_amount([0, 0, amount], true);
//         uint slippage = expectedAmount.mul(100).div(BIPS_DIVISOR);

//         console.log("Expected: %s", expectedAmount);
//         console.log("Slippage: %s", slippage);
//         uint depositAmount = stakingContract.add_liquidity([0, 0, amount], expectedAmount.sub(slippage), true);
//         console.log("Deposit Amount: %s", depositAmount);
//         gaugeContract.deposit(depositAmount);
//     }

//     /**
//      * @notice Safely transfer using an anonymosu ERC20 token
//      * @dev Requires token to return true on transfer
//      * @param token address
//      * @param to recipient address
//      * @param value amount
//      */
//     function _safeTransfer(address token, address to, uint256 value) private {
//         require(IERC20(token).transfer(to, value), 'DexStrategyV6::TRANSFER_FROM_FAILED');
//     }

//     function checkReward() public override view returns (uint) {
//         return gaugeContract.claimable_reward_write(address(this), WAVAX);
//     }

//     function estimateDeployedBalance() external override view returns (uint) {
//         //return stakingContract.balanceOf(address(this));
//     }

//     function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
//         uint balanceBefore = depositToken.balanceOf(address(this));
//         //stakingContract.exit();
//         uint balanceAfter = depositToken.balanceOf(address(this));
//         require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "DexStrategyV6::rescueDeployedFunds");
//         totalDeposits = balanceAfter;
//         emit Reinvest(totalDeposits, totalSupply);
//         if (DEPOSITS_ENABLED == true && disableDeposits == true) {
//             updateDepositsEnabled(false);
//         }
//     }
// }