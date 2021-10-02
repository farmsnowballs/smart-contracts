// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../YakStrategyV2.sol";
import "./interfaces/ICycleVaultV3.sol";
import "./interfaces/ICycleRewards.sol";
import "../../interfaces/IPair.sol";
import "../../lib/DexLibrary.sol";
import "../../lib/SafeERC20.sol";

/**
 * @notice Strategy for CycleVaults
 */
contract CycleStrategyV1 is YakStrategyV2 {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    ICycleVaultV3 public stakingContract;
    ICycleRewards public rewardsContract;
    IPair private swapPairToken0;
    IPair private swapPairToken1;
    IPair private swapPairWAVAXCYCLE;
    address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    constructor (
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _stakingContract,
        address _rewardsContract,
        address _swapPairWAVAXCYCLE,
        address _swapPairToken0,
        address _swapPairToken1,
        address _timelock,
        StrategySettings memory _strategySettings
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardToken = IERC20(_rewardToken);
        rewardsContract = ICycleRewards(_rewardsContract);
        stakingContract = ICycleVaultV3(_stakingContract);
        devAddr = msg.sender;

        swapPairToken0 = IPair(_swapPairToken0);
        swapPairToken1 = IPair(_swapPairToken1);
        swapPairWAVAXCYCLE = IPair(_swapPairWAVAXCYCLE);

        setAllowances();
        applyStrategySettings(_strategySettings);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        emit Reinvest(0, 0);
    }

    function totalDeposits() public override view returns (uint) {
        return stakingContract.getAccountLP(address(this));
    }

    function setAllowances() public override onlyOwner {
        depositToken.approve(address(stakingContract), type(uint256).max);
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
        require(DEPOSITS_ENABLED == true, "CycleStrategyV1::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            uint unclaimedRewards = checkReward();
            if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(unclaimedRewards);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "CycleStrategyV1::transfer failed");
        _mint(account, getSharesForDepositTokens(amount));
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint amount) external override {
        require(amount > 0, "CycleStrategyV1::withdraw");
        uint cycleShares = _convertSharesToCycleShares(amount);
        uint depositTokenAmount = stakingContract.getLPamountForShares(cycleShares);
        stakingContract.withdrawLP(cycleShares);
        IERC20(address(depositToken)).safeTransfer(msg.sender, depositTokenAmount);
        _burn(msg.sender, amount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    function _convertSharesToCycleShares(uint amount) private view returns (uint) {
        uint cycleShareBalance = rewardsContract.balanceOf(address(this));
        return amount.mul(cycleShareBalance).div(totalSupply);
    }

    function reinvest() external override onlyEOA {
        uint unclaimedRewards = checkReward();
        require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "CycleStrategyV1::reinvest");
        _reinvest(unclaimedRewards);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(uint amount) private {
        rewardsContract.getReward();

        uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            IERC20(address(rewardToken)).safeTransfer(devAddr, devFee);
        }

        uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            IERC20(address(rewardToken)).safeTransfer(owner(), adminFee);
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            IERC20(address(rewardToken)).safeTransfer(msg.sender, reinvestFee);
        }

        uint convertedAmountWAVAX = DexLibrary.swap(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee),
            address(rewardToken), WAVAX,
            swapPairWAVAXCYCLE
        );

        uint depositTokenAmount = DexLibrary.convertRewardTokensToDepositTokens(
            convertedAmountWAVAX,
            WAVAX,
            address(depositToken),
            swapPairToken0,
            swapPairToken1
        );

        _stakeDepositTokens(depositTokenAmount);
        emit Reinvest(totalDeposits(), totalSupply);
    }
    
    function _stakeDepositTokens(uint amount) private {
        require(amount > 0, "CycleStrategyV1::_stakeDepositTokens");
        stakingContract.depositLP(amount);
    }

    function checkReward() public override view returns (uint) {
        return rewardsContract.earned(address(this));
    }

    function estimateDeployedBalance() external override view returns (uint) {
        return stakingContract.getAccountLP(address(this));
    }

    function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint balanceBefore = depositToken.balanceOf(address(this));
        stakingContract.withdrawLP(rewardsContract.balanceOf(address(this)));
        uint balanceAfter = depositToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "CycleStrategyV1::rescueDeployedFunds");
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}