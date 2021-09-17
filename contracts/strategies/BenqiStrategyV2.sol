// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategyV2.sol";
import "../interfaces/IBenqiUnitroller.sol";
import "../interfaces/IBenqiERC20Delegator.sol";
import "../interfaces/IWAVAX.sol";

import "../interfaces/IERC20.sol";
import "../lib/DexLibrary.sol";
import "hardhat/console.sol";

contract BenqiStrategyV2 is YakStrategyV2 {
    using SafeMath for uint256;

    IBenqiUnitroller private rewardController;
    IBenqiERC20Delegator private tokenDelegator;
    IERC20 private rewardToken0;
    IERC20 private rewardToken1;
    IPair private swapPairToken0;
    IPair private swapPairToken1;
    IWAVAX private constant WAVAX =
        IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    uint256 private leverageLevel;
    uint256 private leverageBips;
    uint256 private minMinting;
    uint256 private redeemLimitSafetyMargin;

    constructor(
        string memory _name,
        address _depositToken,
        address _rewardController,
        address _tokenDelegator,
        address _rewardToken0,
        address _rewardToken1,
        address _swapPairToken0,
        address _swapPairToken1,
        address _timelock,
        uint256 _minMinting,
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _minTokensToReinvest,
        uint256 _adminFeeBips,
        uint256 _devFeeBips,
        uint256 _reinvestRewardBips
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardController = IBenqiUnitroller(_rewardController);
        tokenDelegator = IBenqiERC20Delegator(_tokenDelegator);
        rewardToken0 = IERC20(_rewardToken0);
        rewardToken1 = IERC20(_rewardToken1);
        rewardToken = rewardToken1;
        minMinting = _minMinting;
        _updateLeverage(
            _leverageLevel,
            _leverageBips,
            _leverageBips.mul(999).div(1000) //works as long as leverageBips > 1000
        );
        devAddr = msg.sender;

        _enterMarket();

        assignSwapPairSafely(_swapPairToken0, _swapPairToken1);
        setAllowances();
        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        emit Reinvest(0, 0);
    }

    function totalDeposits() public view override returns (uint256) {
        (
            ,
            uint256 internalBalance,
            uint256 borrow,
            uint256 exchangeRate
        ) = tokenDelegator.getAccountSnapshot(address(this));
        return internalBalance.mul(exchangeRate).div(1e18).sub(borrow);
    }

    function _totalDepositsFresh() internal returns (uint256) {
        uint256 borrow = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        return balance.sub(borrow);
    }

    function _enterMarket() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenDelegator);
        rewardController.enterMarkets(tokens);
    }

    function _updateLeverage(
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _redeemLimitSafetyMargin
    ) internal {
        leverageLevel = _leverageLevel;
        leverageBips = _leverageBips;
        redeemLimitSafetyMargin = _redeemLimitSafetyMargin;
    }

    function updateLeverage(
        uint256 _leverageLevel,
        uint256 _leverageBips,
        uint256 _redeemLimitSafetyMargin
    ) external onlyDev {
        _updateLeverage(
            _leverageLevel,
            _leverageBips,
            _redeemLimitSafetyMargin
        );
        _unrollDebt();
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        if (balance > 0) {
            _rollupDebt(balance, 0);
        }
    }

    /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading deposit tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken1
     */
    function assignSwapPairSafely(
        address _swapPairToken0,
        address _swapPairToken1
    ) private {
        require(
            _swapPairToken0 > address(0),
            "Swap pair 0 is necessary but not supplied"
        );
        require(
            _swapPairToken1 > address(0),
            "Swap pair 1 is necessary but not supplied"
        );

        require(
            address(rewardToken0) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken0) ==
                IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken0"
        );

        require(
            address(rewardToken1) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken1) ==
                IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken1"
        );

        require(
            address(depositToken) == IPair(address(_swapPairToken1)).token0() ||
                address(depositToken) ==
                IPair(address(_swapPairToken1)).token1(),
            "Swap pair 1 does not match depositToken"
        );

        require(
            address(rewardToken1) == IPair(address(_swapPairToken1)).token0() ||
                address(rewardToken1) ==
                IPair(address(_swapPairToken1)).token1(),
            "Swap pair 1 does not match rewardToken1"
        );

        swapPairToken0 = IPair(_swapPairToken0);
        swapPairToken1 = IPair(_swapPairToken1);
    }

    function setAllowances() public override onlyOwner {
        depositToken.approve(address(tokenDelegator), type(uint256).max);
        tokenDelegator.approve(address(tokenDelegator), type(uint256).max);
    }

    function deposit(uint256 amount) external override {
        _deposit(msg.sender, amount);
    }

    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        depositToken.permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint256 amount) external override {
        _deposit(account, amount);
    }

    function _deposit(address account, uint256 amount)
        private
        onlyAllowedDeposits
    {
        require(DEPOSITS_ENABLED == true, "BenqiStrategyV2::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            (
                uint256 qiRewards,
                uint256 avaxRewards,
                uint256 totalAvaxRewards
            ) = _checkRewards();
            if (totalAvaxRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(qiRewards, avaxRewards, totalAvaxRewards);
            }
        }
        require(
            depositToken.transferFrom(msg.sender, address(this), amount),
            "BenqiStrategyV2::transfer failed"
        );
        uint256 depositTokenAmount = amount;
        uint256 balance = _totalDepositsFresh();
        if (totalSupply.mul(balance) > 0) {
            depositTokenAmount = amount.mul(totalSupply).div(balance);
        }
        _mint(account, depositTokenAmount);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override {
        require(
            amount > minMinting,
            "BenqiStrategyV2:: below minimum withdraw"
        );
        uint256 depositTokenAmount = _totalDepositsFresh().mul(amount).div(
            totalSupply
        );
        if (depositTokenAmount > 0) {
            _burn(msg.sender, amount);
            _withdrawDepositTokens(depositTokenAmount);
            _safeTransfer(
                address(depositToken),
                msg.sender,
                depositTokenAmount
            );
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint256 amount) private {
        _unrollDebtTarget(_getPrincipal().sub(amount));
        require(
            tokenDelegator.redeemUnderlying(amount) == 0,
            "BenqiStrategyV2::failed to redeem"
        );
    }

    function reinvest() external override onlyEOA {
        (
            uint256 qiRewards,
            uint256 avaxRewards,
            uint256 totalAvaxRewards
        ) = _checkRewards();
        require(
            totalAvaxRewards >= MIN_TOKENS_TO_REINVEST,
            "BenqiStrategyV2::reinvest"
        );
        _reinvest(qiRewards, avaxRewards, totalAvaxRewards);
    }

    receive() external payable {
        require(
            msg.sender == address(rewardController),
            "BenqiStrategyV2::payments not allowed"
        );
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(
        uint256 qiRewards,
        uint256 avaxRewards,
        uint256 amount
    ) private {
        rewardController.claimReward(0, address(this));
        rewardController.claimReward(1, address(this));
        if (avaxRewards > 0) {
            WAVAX.deposit{value: avaxRewards}();
        }

        if (qiRewards > 0) {
            DexLibrary.swap(
                qiRewards,
                address(rewardToken0),
                address(rewardToken1),
                swapPairToken0
            );
        }

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(
            BIPS_DIVISOR
        );
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 depositTokenAmount = DexLibrary.swap(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee),
            address(rewardToken1),
            address(depositToken),
            swapPairToken1
        );

        _stakeDepositTokens(depositTokenAmount);

        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _rollupDebt(uint256 principal, uint256 borrowed) internal {
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        uint256 supplied = principal;
        uint256 lendTarget = principal.sub(borrowed).mul(leverageLevel).div(
            leverageBips
        );
        uint256 totalBorrowed = borrowed;
        while (supplied < lendTarget) {
            uint256 toBorrowAmount = _getBorrowable(
                supplied,
                totalBorrowed,
                borrowLimit,
                borrowBips
            );
            if (supplied.add(toBorrowAmount) > lendTarget) {
                toBorrowAmount = lendTarget.sub(supplied);
            }
            // safeguard needed because we can't mint below a certain threshold
            if (toBorrowAmount < minMinting) {
                break;
            }
            require(
                tokenDelegator.borrow(toBorrowAmount) == 0,
                "BenqiStrategyV2::borrowing failed"
            );
            require(
                tokenDelegator.mint(toBorrowAmount) == 0,
                "BenqiStrategyV2::lending failed"
            );
            supplied = tokenDelegator.balanceOfUnderlying(address(this));
            totalBorrowed = totalBorrowed.add(toBorrowAmount);
        }
    }

    function _getRedeemable(
        uint256 balance,
        uint256 borrowed,
        uint256 borrowLimit,
        uint256 bips
    ) internal view returns (uint256) {
        return
            balance
                .sub(borrowed.mul(bips).div(borrowLimit))
                .mul(redeemLimitSafetyMargin)
                .div(leverageBips);
    }

    function _getBorrowable(
        uint256 balance,
        uint256 borrowed,
        uint256 borrowLimit,
        uint256 bips
    ) internal pure returns (uint256) {
        return balance.mul(borrowLimit).div(bips).sub(borrowed);
    }

    function _getPrincipal() internal returns (uint256) {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        return balance.sub(borrowed);
    }

    function _getBorrowLimit() internal view returns (uint256, uint256) {
        (, uint256 borrowLimit) = rewardController.markets(
            address(tokenDelegator)
        );
        return (borrowLimit, 1e18);
    }

    function _unrollDebt() internal {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();

        while (borrowed > 0) {
            uint256 unrollAmount = _getRedeemable(
                balance,
                borrowed,
                borrowLimit,
                borrowBips
            );
            if (unrollAmount > borrowed) {
                unrollAmount = borrowed;
            }
            require(
                tokenDelegator.redeemUnderlying(unrollAmount) == 0,
                "BenqiStrategyV2::failed to redeem"
            );
            require(
                tokenDelegator.repayBorrow(unrollAmount) == 0,
                "BenqiStrategyV2::failed to repay borrow"
            );
            balance = balance.sub(unrollAmount);
            borrowed = borrowed.sub(unrollAmount);
        }
    }

    function _unrollDebtTarget(uint256 targetPrincipal) internal {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        uint256 toRepay = borrowed.sub(
            targetPrincipal.mul(leverageLevel).div(leverageBips).sub(
                targetPrincipal
            )
        );
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        while (toRepay > 0) {
            uint256 unrollAmount = _getRedeemable(
                balance,
                borrowed,
                borrowLimit,
                borrowBips
            );
            if (unrollAmount > toRepay) {
                unrollAmount = toRepay;
            }
            require(
                tokenDelegator.redeemUnderlying(unrollAmount) == 0,
                "BenqiStrategyV2::failed to redeem"
            );
            require(
                tokenDelegator.repayBorrow(unrollAmount) == 0,
                "BenqiStrategyV2::failed to repay borrow"
            );
            balance = balance.sub(unrollAmount);
            borrowed = borrowed.sub(unrollAmount);
            toRepay = toRepay.sub(unrollAmount);
        }

        console.log(tokenDelegator.balanceOfUnderlying(address(this)));
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "BenqiStrategyV2::_stakeDepositTokens");
        require(
            tokenDelegator.mint(amount) == 0,
            "BenqiStrategyV2::Deposit failed"
        );
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 principal = tokenDelegator.balanceOfUnderlying(address(this));
        _rollupDebt(principal, borrowed);
    }

    /**
     * @notice Safely transfer using an anonymosu ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(
            IERC20(token).transfer(to, value),
            "BenqiStrategyV2::TRANSFER_FROM_FAILED"
        );
    }

    function _checkRewards()
        internal
        view
        returns (
            uint256 qiAmount,
            uint256 avaxAmount,
            uint256 totalAvaxAmount
        )
    {
        uint256 qiRewards = _getReward(0, address(this));
        uint256 avaxRewards = _getReward(1, address(this));

        uint256 qiAsWavax = DexLibrary.estimateConversionThroughPair(
            qiRewards,
            address(rewardToken0),
            address(rewardToken1),
            swapPairToken0
        );
        return (qiRewards, avaxRewards, avaxRewards.add(qiAsWavax));
    }

    function checkReward() public view override returns (uint256) {
        (, , uint256 avaxRewards) = _checkRewards();
        return avaxRewards;
    }

    function _getReward(uint8 tokenIndex, address account)
        internal
        view
        returns (uint256)
    {
        uint256 rewardAccrued = rewardController.rewardAccrued(
            tokenIndex,
            account
        );
        (uint224 supplyIndex, ) = rewardController.rewardSupplyState(
            tokenIndex,
            account
        );
        uint256 supplierIndex = rewardController.rewardSupplierIndex(
            tokenIndex,
            address(tokenDelegator),
            account
        );
        uint256 supplyIndexDelta = 0;
        if (supplyIndex > supplierIndex) {
            supplyIndexDelta = supplyIndex - supplierIndex;
        }
        uint256 supplyAccrued = tokenDelegator.balanceOf(account).mul(
            supplyIndexDelta
        );
        (uint224 borrowIndex, ) = rewardController.rewardBorrowState(
            tokenIndex,
            account
        );
        uint256 borrowerIndex = rewardController.rewardBorrowerIndex(
            tokenIndex,
            address(tokenDelegator),
            account
        );
        uint256 borrowIndexDelta = 0;
        if (borrowIndex > borrowerIndex) {
            borrowIndexDelta = borrowIndex - borrowerIndex;
        }
        uint256 borrowAccrued = tokenDelegator.borrowBalanceStored(account).mul(
            borrowIndexDelta
        );
        return rewardAccrued.add(supplyAccrued.sub(borrowAccrued));
    }

    function getActualLeverage() public view returns (uint256) {
        (
            ,
            uint256 internalBalance,
            uint256 borrow,
            uint256 exchangeRate
        ) = tokenDelegator.getAccountSnapshot(address(this));
        uint256 balance = internalBalance.mul(exchangeRate).div(1e18);
        return balance.mul(1e18).div(balance.sub(borrow));
    }

    function estimateDeployedBalance()
        external
        view
        override
        returns (uint256)
    {
        return totalDeposits();
    }

    function rescueDeployedFunds(
        uint256 minReturnAmountAccepted,
        bool disableDeposits
    ) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _unrollDebt();
        tokenDelegator.redeemUnderlying(
            tokenDelegator.balanceOfUnderlying(address(this))
        );
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted,
            "BenqiStrategyV2::rescueDeployedFunds"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}
