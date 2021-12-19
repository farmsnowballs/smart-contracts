// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategyV2.sol";
import "../interfaces/IJoeChef.sol";
import "../interfaces/IJoeBar.sol";
import "../interfaces/IPair.sol";

/**
 * @notice Single asset strategy for Joe
 */
contract CompoundingJoeV2 is YakStrategyV2 {
    using SafeMath for uint256;

    IJoeChef public stakingContract;
    IJoeBar public conversionContract;
    IERC20 public xJoe;

    uint256 public PID;

    constructor(
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _stakingContract,
        address _conversionContract,
        address _timelock,
        uint256 _pid,
        uint256 _minTokensToReinvest,
        uint256 _adminFeeBips,
        uint256 _devFeeBips,
        uint256 _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IPair(_depositToken);
        rewardToken = IERC20(_rewardToken);
        stakingContract = IJoeChef(_stakingContract);
        conversionContract = IJoeBar(_conversionContract);
        xJoe = IERC20(_conversionContract);
        PID = _pid;
        devAddr = 0x2D580F9CF2fB2D09BC411532988F2aFdA4E7BefF;

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
        depositToken.approve(address(conversionContract), MAX_UINT);
        xJoe.approve(address(stakingContract), MAX_UINT);
    }

    /**
     * @notice Deposit tokens to receive receipt tokens
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external override {
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
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint256 amount) external override {
        _deposit(account, amount);
    }

    /**
     * @notice Deposit Joe
     * @param account address
     * @param amount token amount
     */
    function _deposit(address account, uint256 amount) internal {
        require(DEPOSITS_ENABLED == true, "CompoundingJoeV2::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            uint256 unclaimedRewards = checkReward();
            if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(unclaimedRewards);
            }
        }

        require(depositToken.transferFrom(msg.sender, address(this), amount));
        _mint(account, getSharesForDepositTokens(amount));
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override {
        uint256 depositTokenAmount = getDepositTokensForShares(amount);
        require(depositTokenAmount > 0, "CompoundingJoeV2::withdraw");
        _withdrawDepositTokens(depositTokenAmount);
        require(
            depositToken.transfer(msg.sender, depositTokenAmount),
            "CompoundingJoeV2::withdraw transfer failed"
        );
        _burn(msg.sender, amount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    /**
     * @notice Withdraw Joe
     * @param amount deposit tokens
     */
    function _withdrawDepositTokens(uint256 amount) private {
        uint256 xJoeAmount = _getXJoeForJoe(amount);
        stakingContract.withdraw(PID, xJoeAmount);
        conversionContract.leave(xJoeAmount);
    }

    function reinvest() external override onlyEOA {
        uint256 unclaimedRewards = checkReward();
        require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "CompoundingJoeV2::reinvest");
        _reinvest(unclaimedRewards);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(uint256 amount) private {
        stakingContract.deposit(PID, 0);

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            require(
                rewardToken.transfer(devAddr, devFee),
                "CompoundingJoeV2::_reinvest, dev"
            );
        }

        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            require(
                rewardToken.transfer(msg.sender, reinvestFee),
                "CompoundingJoeV2::_reinvest, reward"
            );
        }

        uint256 depositTokenAmount = amount.sub(devFee).sub(reinvestFee);
        _stakeDepositTokens(depositTokenAmount);

        emit Reinvest(totalDeposits(), totalSupply);
    }

    /**
     * @notice Convert and stake Joe
     * @param amount deposit tokens
     */
    function _stakeDepositTokens(uint256 amount) private {
        uint256 xJoeAmount = _getXJoeForJoe(amount);
        require(xJoeAmount > 0, "CompoundingJoeV2::_stakeDepositTokens");
        _convertJoeToXJoe(amount);
        _stakeXJoe(xJoeAmount);
    }

    /**
     * @notice Convert joe to xJoe
     * @param amount deposit token
     */
    function _convertJoeToXJoe(uint256 amount) private {
        conversionContract.enter(amount);
    }

    /**
     * @notice Stake xJoe
     * @param amount xJoe
     */
    function _stakeXJoe(uint256 amount) private {
        stakingContract.deposit(PID, amount);
    }

    function checkReward() public view override returns (uint256) {
        (uint256 pendingReward, , , ) = stakingContract.pendingTokens(
            PID,
            address(this)
        );
        uint256 contractBalance = rewardToken.balanceOf(address(this));
        return pendingReward.add(contractBalance);
    }

    function totalDeposits() public view override returns (uint256) {
        (uint256 depositBalance, ) = stakingContract.userInfo(PID, address(this));
        return _getJoeForXJoe(depositBalance);
    }

    /**
     * @notice Estimate recoverable balance
     * @return deposit tokens
     */
    function estimateDeployedBalance() external view override returns (uint256) {
        (uint256 depositBalance, ) = stakingContract.userInfo(PID, address(this));
        return _getJoeForXJoe(depositBalance);
    }

    /**
     * @notice Conversion rate for Joe to xJoe
     * @param amount Joe tokens
     * @return xJoe shares
     */
    function _getXJoeForJoe(uint256 amount) private view returns (uint256) {
        uint256 joeBalance = depositToken.balanceOf(address(conversionContract));
        uint256 xJoeShares = xJoe.totalSupply();
        if (joeBalance.mul(xJoeShares) == 0) {
            return amount;
        }
        return amount.mul(xJoeShares).div(joeBalance);
    }

    /**
     * @notice Conversion rate for xJoe to Joe
     * @param amount xJoe shares
     * @return Joe tokens
     */
    function _getJoeForXJoe(uint256 amount) private view returns (uint256) {
        uint256 joeBalance = depositToken.balanceOf(address(conversionContract));
        uint256 xJoeShares = xJoe.totalSupply();
        if (joeBalance.mul(xJoeShares) == 0) {
            return amount;
        }
        return amount.mul(joeBalance).div(xJoeShares);
    }

    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits)
        external
        override
        onlyOwner
    {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        stakingContract.emergencyWithdraw(PID);
        conversionContract.leave(xJoe.balanceOf(address(this)));
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted,
            "CompoundingJoeV2::rescueDeployedFunds"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}
