// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategy.sol";
import "../interfaces/IStakingRewards.sol";
import "../interfaces/IPair.sol";

/**
 * @notice Pool2 strategy for StakingRewards
 */
contract DexStrategyV5Reflection is YakStrategy {
    using SafeMath for uint;

    IStakingRewards public stakingContract;
    IPair public swapPairToken0;
    IPair public swapPairToken1;
    bytes zeroBytes;
    uint public burnFeeBips;
    address public reflectionToken;

    constructor (
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _stakingContract,
        address _swapPairToken0,
        address _swapPairToken1,
        address _reflectionToken,
        address _timelock,
        uint _minTokensToReinvest,
        uint _adminFeeBips,
        uint _devFeeBips,
        uint _reinvestRewardBips,
        uint _burnFeeBips
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardToken = IERC20(_rewardToken);
        stakingContract = IStakingRewards(_stakingContract);
        devAddr = msg.sender;
        burnFeeBips = _burnFeeBips;

        reflectionToken = _reflectionToken;
        assignSwapPairSafely(_swapPairToken0, _swapPairToken1, _rewardToken);
        setAllowances();
        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);

        zeroBytes = new bytes(0);

        emit Reinvest(0, 0);
    }

    function assignSwapPairSafely(address _swapPairToken0, address _swapPairToken1, address _rewardToken) internal {
        if (_rewardToken != IPair(address(depositToken)).token0() && _rewardToken != IPair(address(depositToken)).token1()) {
            // deployment checks for non-pool2
            require(_swapPairToken0 > address(0), "Swap pair 0 is necessary but not supplied");
            require(_swapPairToken1 > address(0), "Swap pair 1 is necessary but not supplied");
            // should match pairToken.token0()
            swapPairToken0 = IPair(_swapPairToken0);
            // should match pairToken.token1()
            swapPairToken1 = IPair(_swapPairToken1);
            require(
                swapPairToken0.token0() == _rewardToken || swapPairToken0.token1() == _rewardToken,
                "Swap pair supplied does not have the reward token as one of it's pair"
            );
            require(
                swapPairToken0.token0() == IPair(address(depositToken)).token0() || swapPairToken0.token1() == IPair(address(depositToken)).token0(),
                "Swap pair 0 supplied does not match the pair in question"
            );
            require(
                swapPairToken1.token0() == IPair(address(depositToken)).token1() || swapPairToken1.token1() == IPair(address(depositToken)).token1(),
                "Swap pair 1 supplied does not match the pair in question"
            );
        } else if (_rewardToken == IPair(address(depositToken)).token0()) {
            // pool2 case
            swapPairToken1 = IPair(address(depositToken));
        } else if (_rewardToken == IPair(address(depositToken)).token1()) {
            // pool2 case
            swapPairToken0 = IPair(address(depositToken));
        }
    }

    function setAllowances() public override onlyOwner {
        depositToken.approve(address(stakingContract), MAX_UINT);
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
        require(DEPOSITS_ENABLED == true, "DexStrategyV5::_deposit");
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
            require(depositToken.transfer(msg.sender, depositTokenAmount), "DexStrategyV5::withdraw");
            _burn(msg.sender, amount);
            totalDeposits = totalDeposits.sub(depositTokenAmount);
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint amount) private {
        require(amount > 0, "DexStrategyV5::_withdrawDepositTokens");
        stakingContract.withdraw(amount);
    }

    function reinvest() external override onlyEOA {
        uint unclaimedRewards = checkReward();
        require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "DexStrategyV5::reinvest");
        _reinvest(unclaimedRewards);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     */
    function _reinvest(uint amount) private {
        stakingContract.getReward();

        uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            require(rewardToken.transfer(devAddr, devFee), "DexStrategyV5::_reinvest, dev");
        }

        uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            require(rewardToken.transfer(owner(), adminFee), "DexStrategyV5::_reinvest, admin");
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            require(rewardToken.transfer(msg.sender, reinvestFee), "DexStrategyV5::_reinvest, reward");
        }

        uint depositTokenAmount = _convertRewardTokensToDepositTokens(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee)
        );

        _stakeDepositTokens(depositTokenAmount);
        totalDeposits = totalDeposits.add(depositTokenAmount);

        emit Reinvest(totalDeposits, totalSupply);
    }
    
    function _stakeDepositTokens(uint amount) private {
        require(amount > 0, "DexStrategyV5::_stakeDepositTokens");
        stakingContract.stake(amount);
    }

    /** 
     * @notice Given two tokens, it'll return the tokens in the right order for the tokens pair
     * @dev TokenA must be different from TokenB, and both shouldn't be address(0), no validations
     */
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /**
     * @notice Given an input amount of an asset and pair reserves, returns maximum output amount of the other asset
     * @dev Assumes swap fee is 0.30%
     * @param amountIn input asset
     * @param reserveIn size of input asset reserve
     * @param reserveOut size of output asset reserve
     * @return amountOut maximum output amount
     */
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        // this is trusting that reserveIn > 0 and reserveOut > 0
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    /**
     * @notice Safely transfer using an anonymous ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(address token, address to, uint256 value) internal {
        require(IERC20(token).transfer(address(to), value), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    /**
     * @notice Quote liquidity amount out
     * @param amountIn input tokens
     * @param reserve0 size of input asset reserve
     * @param reserve1 size of output asset reserve
     * @return liquidity tokens
     */
    function _quoteLiquidityAmountOut(uint amountIn, uint reserve0, uint reserve1) internal pure returns (uint) {
        return amountIn.mul(reserve1).div(reserve0);
    }

    /**
     * @notice Add liquidity directly through a Pair
     * @dev Checks adding the max of each token amount
     * @param token0 address
     * @param token1 address
     * @param maxAmountIn0 amount token0
     * @param maxAmountIn1 amount token1
     * @return liquidity tokens
     */
    function _addLiquidity(address token0, address token1, uint maxAmountIn0, uint maxAmountIn1) internal returns (uint) {
        (uint112 reserve0, uint112 reserve1,) = IPair(address(depositToken)).getReserves();
        // max token0, and gets the quote for token1
        uint amountIn1 = _quoteLiquidityAmountOut(maxAmountIn0, reserve0, reserve1);
        // if the quote exceeds our balance then max token1 instead
        if (amountIn1 > maxAmountIn1) {
            amountIn1 = maxAmountIn1;
            maxAmountIn0 = _quoteLiquidityAmountOut(maxAmountIn1, reserve1, reserve0);
        }
        _safeTransfer(token0, address(depositToken), maxAmountIn0);
        _safeTransfer(token1, address(depositToken), amountIn1);
        uint minted = IPair(address(depositToken)).mint(address(this));
        IPair(address(depositToken)).sync();
        return minted;
    }

    /**
     * @notice Swap directly through a Pair
     * @param amountIn input amount
     * @param fromToken address
     * @param toToken address
     * @param pair Pair used for swap
     * @return output amount
     */
    function _swap(uint amountIn, address fromToken, address toToken, IPair pair) internal returns (uint) {
        // computes the reserves in the correct pair order
        (address token0,) = sortTokens(fromToken, toToken);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (token0 != fromToken) (reserve0, reserve1) = (reserve1, reserve0);
        // gets the expected amount out
        uint amountOut1 = 0;
        uint amountOut2 = getAmountOut(amountIn, reserve0, reserve1);
        if (token0 != fromToken) (amountOut1, amountOut2) = (amountOut2, amountOut1);
        // sends the input of the swap
        _safeTransfer(fromToken, address(pair), amountIn);
        // gets the output of the swap
        pair.swap(amountOut1, amountOut2, address(this), zeroBytes);
        if (toToken == reflectionToken) pair.sync();
        return amountOut2 > amountOut1 ? amountOut2 : amountOut1;
    }

    /**
     * @notice Computes how much dust of token the contract has in the reward token proportion
     * @dev token must match the swapPair. It assumes swapPair is a pair of token-rewardToken
     */
    function _getDustInRewardToken(address token, IPair swapPair) internal view returns (uint) {
        (address firstToken,) = sortTokens(address(rewardToken), token);
        (uint112 reserve0, uint112 reserve1,) = swapPair.getReserves();
        if (token != firstToken) (reserve0, reserve1) = (reserve1, reserve0);
        return getAmountOut(
            IERC20(token).balanceOf(address(this)),
            reserve0, reserve1
        );
    }

    /**
     * @notice Converts reward tokens to deposit tokens
     * @dev No price checks enforced
     * @param amount reward tokens
     * @return deposit tokens
     */
    function _convertRewardTokensToDepositTokens(uint amount) private returns (uint) {
        uint token0BalanceFactor = _getDustInRewardToken(IPair(address(depositToken)).token0(), swapPairToken0);
        uint token1BalanceFactor = _getDustInRewardToken(IPair(address(depositToken)).token1(), swapPairToken1);

        //amount that will be burned
        uint burnBalance = amount.mul(burnFeeBips).div(BIPS_DIVISOR);
        //higher quantity should go into the token that will burn
        uint amountIn0 = amount.sub(token0BalanceFactor).add(token1BalanceFactor).add(burnBalance).div(2);
        uint amountIn1 = amount.sub(token1BalanceFactor).add(token0BalanceFactor).sub(burnBalance).div(2);
        if (IPair(address(depositToken)).token0() != reflectionToken) {
            (amountIn0, amountIn1) = (amountIn1, amountIn0);
        }

        // swap to token0
        if (address(rewardToken) != IPair(address(depositToken)).token0()) {
            _swap(
                amountIn0, address(rewardToken),
                IPair(address(depositToken)).token0(), swapPairToken0
            );
        }

        // swap to token1
        if (address(rewardToken) != IPair(address(depositToken)).token1()) {
            _swap(
                amountIn1, address(rewardToken),
                IPair(address(depositToken)).token1(), swapPairToken1
            );
        }

        return _addLiquidity(
            IPair(address(depositToken)).token0(), IPair(address(depositToken)).token1(),
            IERC20(IPair(address(depositToken)).token0()).balanceOf(address(this)),
            IERC20(IPair(address(depositToken)).token1()).balanceOf(address(this))
        );
    }
    
    function checkReward() public override view returns (uint) {
        return stakingContract.earned(address(this));
    }

    function estimateDeployedBalance() external override view returns (uint) {
        return stakingContract.balanceOf(address(this));
    }

    function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint balanceBefore = depositToken.balanceOf(address(this));
        stakingContract.exit();
        uint balanceAfter = depositToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "DexStrategyV5::rescueDeployedFunds");
        totalDeposits = balanceAfter;
        emit Reinvest(totalDeposits, totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}