// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategyV2.sol";
import "../interfaces/marginswap/ILending.sol";
import "../interfaces/IWAVAX.sol";

import "../interfaces/IERC20.sol";
import "../lib/DexLibrary.sol";

contract MarginswapStrategyV1 is YakStrategyV2 {
    using SafeMath for uint;

    ILending public stakingContract;
    address private fundContract;
    IPair private swapPairWAVAXMfi;
    IPair private swapPairToken;
    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    uint private leverageLevel;
    uint private leverageBips;

    constructor (
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _stakingContract,
        address _fundContract,
        address _swapPairWAVAXMfi,
        address _swapPairToken,
        address _timelock,
        uint _minTokensToReinvest,
        uint _adminFeeBips,
        uint _devFeeBips,
        uint _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardToken = IERC20(_rewardToken);
        stakingContract = ILending(_stakingContract);
        fundContract = _fundContract;
        swapPairWAVAXMfi = IPair(_swapPairWAVAXMfi);
        swapPairToken = IPair(_swapPairToken);
        devAddr = 0x2D580F9CF2fB2D09BC411532988F2aFdA4E7BefF;

        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        emit Reinvest(0, 0);
    }

    function totalDeposits() public override view returns (uint) {
        return stakingContract.viewHourlyBondAmount(address(depositToken), address(this));
    }

    function setAllowances() public override onlyOwner {
        revert("deprecated");
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
        require(DEPOSITS_ENABLED == true, "MarginswapStrategyV1::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            uint unclaimedRewards = checkReward();
            if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(unclaimedRewards);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "MarginswapStrategyV1::transfer failed");
        uint shares = amount;
        if (totalSupply.mul(totalDeposits()) > 0) {
            shares = amount.mul(totalSupply).div(totalDeposits());
        }
        _mint(account, shares);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint amount) external override {
        uint depositTokenAmount = totalDeposits().mul(amount).div(totalSupply);
        require(amount > 0, "MarginswapStrategyV1::withdraw");
        _burn(msg.sender, amount);
        _withdrawDepositTokens(depositTokenAmount);
        _safeTransfer(address(depositToken), msg.sender, depositTokenAmount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    function _withdrawDepositTokens(uint amount) private {
        stakingContract.withdrawHourlyBond(address(depositToken), amount);
    }

    function reinvest() external override onlyEOA {
        uint unclaimedRewards = checkReward();
        require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "MarginswapStrategyV1::reinvest");
        _reinvest(unclaimedRewards);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(uint amount) private {
        stakingContract.withdrawIncentive(address(depositToken));

        uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint depositTokenAmount = amount.sub(devFee).sub(reinvestFee);
        if (address(swapPairWAVAXMfi) != address(0)) {
            if (address(swapPairToken) != address(0)) {
                uint amountWavax = DexLibrary.swap(depositTokenAmount, address(rewardToken), address(WAVAX), swapPairWAVAXMfi);
                depositTokenAmount = DexLibrary.swap(amountWavax, address(WAVAX), address(depositToken), swapPairToken);
            }
            else {
                depositTokenAmount = DexLibrary.swap(depositTokenAmount, address(rewardToken), address(WAVAX), swapPairWAVAXMfi);
            }
        }
        else if (address(swapPairToken) != address(0)) {
            depositTokenAmount = DexLibrary.swap(depositTokenAmount, address(rewardToken), address(depositToken), swapPairToken);
        }

        _stakeDepositTokens(depositTokenAmount);

        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _stakeDepositTokens(uint amount) private {
        require(amount > 0, "MarginswapStrategyV1::_stakeDepositTokens");
        depositToken.approve(address(fundContract), amount);
        stakingContract.buyHourlyBondSubscription(address(depositToken), amount);
    }

    /**
     * @notice Safely transfer using an anonymosu ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        require(IERC20(token).transfer(to, value), 'MarginswapStrategyV1::TRANSFER_FROM_FAILED');
    }

    function checkReward() public override view returns (uint) {
        uint balance = rewardToken.balanceOf(address(this));
        return balance.add(_calculateIncentiveAllocation());
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        if (a > b) {
            return b;
        } else {
            return a;
        }
    }

    function _calculateIncentiveAllocation() private view returns (uint) {
        (uint256 totalLending,
        uint256 totalBorrowed,
        uint256 lendingCap,
        uint256 cumulIncentiveAllocationFP,
        uint256 incentiveLastUpdated,
        uint256 incentiveEnd,
        uint256 incentiveTarget) = stakingContract.lendingMeta(address(depositToken));

        uint256 endTime = min(incentiveEnd, block.timestamp);
        if (incentiveTarget > 0 && endTime > incentiveLastUpdated) {
            uint256 timeDelta = endTime.sub(incentiveLastUpdated);
            uint256 targetDelta =
                min(
                    incentiveTarget,
                    (timeDelta.mul(incentiveTarget)).div((incentiveEnd.sub(incentiveLastUpdated)))
                );
            incentiveTarget = incentiveTarget.sub(targetDelta);
            cumulIncentiveAllocationFP = cumulIncentiveAllocationFP.add(
                (targetDelta.mul(2**48)).div((uint(1).add(totalLending)))
            );
            incentiveLastUpdated = block.timestamp;
        }

        (uint bondAmount,,,uint incentiveAllocationStart) = stakingContract.hourlyBondAccounts(address(depositToken), address(this));

        uint allocationDelta = cumulIncentiveAllocationFP.sub(incentiveAllocationStart);
        if (allocationDelta > 0) {
            uint disburseAmount = allocationDelta.mul(bondAmount).div(2**48);
            return disburseAmount;
        }
        return 0;
    }

    function estimateDeployedBalance() external override view returns (uint) {
        return totalDeposits();
    }

    function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint balanceBefore = depositToken.balanceOf(address(this));
        stakingContract.withdrawHourlyBond(address(depositToken), minReturnAmountAccepted);
        depositToken.approve(address(fundContract), 0);
        uint balanceAfter = depositToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "MarginswapStrategyV1::rescueDeployedFunds");
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}

