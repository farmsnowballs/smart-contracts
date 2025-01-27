// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../../BaseStrategy.sol";
import "./CamelotXGrailRewarder.sol";
import "./../../../interfaces/IPair.sol";

import "./interfaces/INFTPool.sol";
import "./interfaces/ICamelotVoterProxy.sol";
import "./interfaces/ICamelotLP.sol";
import "./interfaces/INitroPool.sol";

contract CamelotStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    struct CamelotStrategySettings {
        address nftPool;
        uint256 positionId;
        address nitroPool;
        address voterProxy;
    }

    address public constant GRAIL = 0x3d9907F9a368ad0a51Be60f7Da3b97cf940982D8;

    address public immutable pool;
    uint256 public immutable positionId;
    CamelotXGrailRewarder public immutable xGrailRewarder;

    ICamelotVoterProxy public proxy;
    address public nitroPool;

    constructor(
        CamelotStrategySettings memory _camelotStrategySettings,
        BaseStrategySettings memory _variableRewardsStrategySettings,
        StrategySettings memory _strategySettings
    ) BaseStrategy(_variableRewardsStrategySettings, _strategySettings) {
        pool = _camelotStrategySettings.nftPool;
        nitroPool = _camelotStrategySettings.nitroPool;
        positionId = _camelotStrategySettings.positionId;
        proxy = ICamelotVoterProxy(_camelotStrategySettings.voterProxy);
        xGrailRewarder = new CamelotXGrailRewarder(IERC20(address(proxy.voter())), address(this));
    }

    function setVoterProxy(address _voterProxy) external onlyOwner {
        proxy = ICamelotVoterProxy(_voterProxy);
    }

    /**
     * @notice Updates nitro pool
     * @dev Use NitroPoolFactory.nftPoolPublishedNitroPoolsLength and getNftPoolPublishedNitroPool to find a suitable nitro pool
     * @param _nitroPoolIndex Relativ index for this NFTPool
     * @param _useNewNitroPool Pass false if there is no nitro pool available anymore
     */
    function updateNitroPool(uint256 _nitroPoolIndex, bool _useNewNitroPool) external onlyDev {
        nitroPool = proxy.updateNitroPool(positionId, nitroPool, pool, _useNewNitroPool, _nitroPoolIndex);
    }

    /**
     * @notice Failsafe for when selected nitro pool has ended and would block withdrawals
     */
    function withdrawFromEndedNitroPool() external {
        (,,, uint256 depositEndTime,,,,,) = INitroPool(nitroPool).settings();
        require(
            depositEndTime > 0 && depositEndTime < block.timestamp, "CamelotStrategy::withdrawFromNitroPool not allowed"
        );
        proxy.updateNitroPool(positionId, nitroPool, pool, false, 0);
        nitroPool = address(0);
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        proxy.claimReward(positionId, pool, nitroPool, address(xGrailRewarder));
        uint256 yyGrailAmount = xGrailRewarder.depositFor(msg.sender, getSharesForDepositTokens(_amount));
        _redeemXGrail(msg.sender, yyGrailAmount);
        depositToken.safeTransfer(address(proxy.voter()), _amount);
        proxy.deposit(positionId, pool, address(depositToken), _amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        proxy.claimReward(positionId, pool, nitroPool, address(xGrailRewarder));
        uint256 yyGrailAmount = xGrailRewarder.withdrawFor(msg.sender, getSharesForDepositTokens(_amount));
        _redeemXGrail(msg.sender, yyGrailAmount);
        proxy.withdraw(positionId, pool, nitroPool, address(depositToken), _amount);
        return _amount;
    }

    function _redeemXGrail(address _account, uint256 _amount) internal {
        if (_amount > 0) {
            proxy.convertToXGrail(pool, positionId, _amount, _account);
        }
    }

    function claimReward() external {
        uint256 yyGrailAmount = xGrailRewarder.depositFor(msg.sender, 0);
        _redeemXGrail(msg.sender, yyGrailAmount);
    }

    function _pendingRewards() internal view virtual override returns (Reward[] memory) {
        return proxy.pendingRewards(positionId, pool, nitroPool);
    }

    function _getRewards() internal virtual override {
        proxy.claimReward(positionId, pool, nitroPool, address(xGrailRewarder));
    }

    function _convertRewardTokenToDepositToken(uint256 fromAmount) internal override returns (uint256 toAmount) {
        uint256 amountIn = fromAmount / 2;
        require(amountIn > 0, "DexLibrary::_convertRewardTokensToDepositTokens");

        address token0 = IPair(address(depositToken)).token0();
        uint256 amountOutToken0 = amountIn;
        if (address(rewardToken) != token0) {
            FormattedOffer memory offer = simpleRouter.query(amountIn, address(rewardToken), token0);
            amountOutToken0 = _swap(offer);
        }

        address token1 = IPair(address(depositToken)).token1();
        uint256 amountOutToken1 = amountIn;
        if (address(rewardToken) != token1) {
            FormattedOffer memory offer = simpleRouter.query(amountIn, address(rewardToken), token1);
            amountOutToken1 = _swap(offer);
        }

        (uint112 reserve0, uint112 reserve1,) = IPair(address(depositToken)).getReserves();
        uint256 amountIn1 = _quoteLiquidityAmountOut(amountOutToken0, reserve0, reserve1);
        if (amountIn1 > amountOutToken1) {
            amountIn1 = amountOutToken1;
            amountOutToken0 = _quoteLiquidityAmountOut(amountOutToken1, reserve1, reserve0);
        }

        IERC20(token0).safeTransfer(address(depositToken), amountOutToken0);
        IERC20(token1).safeTransfer(address(depositToken), amountIn1);
        return IPair(address(depositToken)).mint(address(this));
    }

    function _quoteLiquidityAmountOut(uint256 amountIn, uint256 reserve0, uint256 reserve1)
        private
        pure
        returns (uint256)
    {
        return (amountIn * reserve1) / reserve0;
    }

    function totalDeposits() public view override returns (uint256) {
        uint256 depositBalance = proxy.poolBalance(positionId, pool);
        return depositBalance;
    }

    function _emergencyWithdraw() internal override {
        proxy.emergencyWithdraw(positionId, pool, nitroPool, address(depositToken));
    }
}
