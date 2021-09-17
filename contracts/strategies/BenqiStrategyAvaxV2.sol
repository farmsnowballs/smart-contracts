// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategyV2Payable.sol";
import "../interfaces/IBenqiUnitroller.sol";
import "../interfaces/IBenqiAVAXDelegator.sol";
import "../interfaces/IWAVAX.sol";

import "../interfaces/IERC20.sol";
import "../lib/DexLibrary.sol";
import "../lib/ReentrancyGuard.sol";

contract BenqiStrategyAvaxV2 is YakStrategyV2Payable, ReentrancyGuard {
    using SafeMath for uint256;

    IBenqiUnitroller private rewardController;
    IBenqiAVAXDelegator private tokenDelegator;
    IERC20 private rewardToken0;
    IPair private swapPairToken0; // swaps rewardToken0 to WAVAX
    IWAVAX private constant WAVAX =
        IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    uint256 private leverageLevel;
    uint256 private leverageBips;
    uint256 private minMinting;
    uint256 private redeemLimitSafetyMargin;

    constructor(
        string memory _name,
        address _rewardController,
        address _tokenDelegator,
        address _rewardToken0,
        address _swapPairToken0,
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
        depositToken = IERC20(address(0));
        rewardController = IBenqiUnitroller(_rewardController);
        tokenDelegator = IBenqiAVAXDelegator(_tokenDelegator);
        rewardToken0 = IERC20(_rewardToken0);
        rewardToken = IERC20(address(WAVAX));
        minMinting = _minMinting;
        _updateLeverage(
            _leverageLevel,
            _leverageBips,
            _leverageBips.mul(990).div(1000) //works as long as leverageBips > 1000
        );
        devAddr = msg.sender;

        _enterMarket();

        assignSwapPairSafely(_swapPairToken0);
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
    function assignSwapPairSafely(address _swapPairToken0) private {
        require(
            _swapPairToken0 > address(0),
            "Swap pair 0 is necessary but not supplied"
        );

        require(
            address(rewardToken0) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken0) ==
                IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken0"
        );

        require(
            address(WAVAX) == IPair(address(_swapPairToken0)).token0() ||
                address(WAVAX) == IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match WAVAX"
        );

        swapPairToken0 = IPair(_swapPairToken0);
    }

    function setAllowances() public override onlyOwner {
        tokenDelegator.approve(address(tokenDelegator), type(uint256).max);
    }

    function deposit() external payable override nonReentrant {
        _deposit(msg.sender, msg.value);
    }

    function depositFor(address account)
        external
        payable
        override
        nonReentrant
    {
        _deposit(account, msg.value);
    }

    function deposit(uint256 amount) external override {
        revert();
    }

    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        revert();
    }

    function depositFor(address account, uint256 amount) external override {
        revert();
    }

    function _deposit(address account, uint256 amount)
        private
        onlyAllowedDeposits
    {
        require(DEPOSITS_ENABLED == true, "BenqiStrategyV1::_deposit");
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
        uint256 depositTokenAmount = amount;
        uint256 balance = _totalDepositsFresh();
        if (totalSupply.mul(balance) > 0) {
            depositTokenAmount = amount.mul(totalSupply).div(balance);
        }
        _mint(account, depositTokenAmount);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override nonReentrant {
        uint256 balance = balances[msg.sender];
        if (amount > balance) amount = balance;
        require(amount > minMinting, "BenqiStrategyV1::below minimum withdraw");
        uint256 depositTokenAmount = _totalDepositsFresh().mul(amount).div(
            totalSupply
        );
        if (depositTokenAmount > 0) {
            _burn(msg.sender, amount);
            _withdrawDepositTokens(depositTokenAmount);
            (bool success, ) = msg.sender.call{value: depositTokenAmount}("");
            require(success, "BenqiStrategyV1::withdraw transfer failed");
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint256 amount) private {
        _unrollDebtToFreeTarget(amount);
        require(
            tokenDelegator.redeemUnderlying(amount) == 0,
            "BenqiStrategyV2::failed to redeem"
        );
    }

    function reinvest() external override onlyEOA nonReentrant {
        (
            uint256 qiRewards,
            uint256 avaxRewards,
            uint256 totalAvaxRewards
        ) = _checkRewards();
        require(
            totalAvaxRewards >= MIN_TOKENS_TO_REINVEST,
            "BenqiStrategyV1::reinvest"
        );
        _reinvest(qiRewards, avaxRewards, totalAvaxRewards);
    }

    receive() external payable {
        require(
            msg.sender == address(rewardController) ||
                msg.sender == address(WAVAX) ||
                msg.sender == address(tokenDelegator),
            "BenqiStrategyV1::payments not allowed"
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

        if (qiRewards > 0) {
            uint256 convertedWavax = DexLibrary.swap(
                qiRewards,
                address(rewardToken0),
                address(WAVAX),
                swapPairToken0
            );
            WAVAX.withdraw(convertedWavax);
        }

        amount = address(this).balance;

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        uint256 adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(
            BIPS_DIVISOR
        );
        WAVAX.deposit{value: devFee.add(adminFee).add(reinvestFee)}();
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        _stakeDepositTokens(amount.sub(devFee).sub(adminFee).sub(reinvestFee));

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
                "BenqiStrategyV1::borrowing failed"
            );
            tokenDelegator.mint{value: toBorrowAmount}();
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
                "BenqiStrategyV1::failed to redeem"
            );
            tokenDelegator.repayBorrow{value: unrollAmount}();
            balance = tokenDelegator.balanceOfUnderlying(address(this));
            borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        }
    }

    function _unrollDebtToFreeTarget(uint256 amount) internal {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        uint256 targetPrincipal = balance.sub(borrowed).sub(amount);
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
            tokenDelegator.repayBorrow{value: unrollAmount}();
            balance = tokenDelegator.balanceOfUnderlying(address(this));
            borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
            toRepay = borrowed.sub(
                targetPrincipal.mul(leverageLevel).div(leverageBips).sub(
                    targetPrincipal
                )
            );
        }
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "BenqiStrategyV1::_stakeDepositTokens");
        tokenDelegator.mint{value: amount}();
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
            "BenqiStrategyV1::TRANSFER_FROM_FAILED"
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
            address(WAVAX),
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
            "BenqiStrategyV1::rescueDeployedFunds"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}
