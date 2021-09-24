// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../MasterChefStrategyV1.sol";
import "./interfaces/IJoeMasterChef.sol";
import "../../lib/SafeMath.sol";
import "../../lib/DexLibrary.sol";
import "../../interfaces/IERC20.sol";
import "../../interfaces/IPair.sol";

contract JoeStrategy is MasterChefStrategyV1 {
    using SafeMath for uint256;

    IJoeMasterChef public masterChef;
    address public immutable WAVAXToken;

    address public immutable joeToken;

    address public immutable swapPairJoeWavax;
    address public swapPairExtraToken;
    address public extraToken;

    constructor(
        string memory _name,
        address _depositToken,
        address _rewardToken,
        address _swapPairToken0, // swap wavax to token0
        address _swapPairToken1, // swap wavax to token1
        address _stakingRewards,
        address _timelock,
        uint256 _pid,
        address _joeToken,
        address _swapPairJoeWavax,
        address _swapPairExtraToken,
        uint256 _minTokensToReinvest,
        uint256 _adminFeeBips,
        uint256 _devFeeBips,
        uint256 _reinvestRewardBips
    )
        Ownable()
        MasterChefStrategyV1(
            _name,
            _depositToken,
            _rewardToken,
            _swapPairToken0,
            _swapPairToken1,
            _stakingRewards,
            _timelock,
            _pid,
            _minTokensToReinvest,
            _adminFeeBips,
            _devFeeBips,
            _reinvestRewardBips
        )
    {
        masterChef = IJoeMasterChef(_stakingRewards);
        joeToken = _joeToken;
        swapPairJoeWavax = _swapPairJoeWavax;
        swapPairExtraToken = _swapPairExtraToken;
        WAVAXToken = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

        if (extraToken != address(0)) {
            extraToken == IPair(_swapPairExtraToken).token0();
            if (
                IPair(_swapPairExtraToken).token0() ==
                0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
            ) {
                extraToken == IPair(_swapPairExtraToken).token1();
            }
        } else {
            extraToken = address(0);
        }
    }

    function setExtraSwapPair(uint256 pid, address swapPair)
        external
        onlyOwner
    {
        if (swapPair == address(0)) {
            swapPairExtraToken = address(0);
            return;
        }

        (, address extraRewardToken, , ) = masterChef.pendingTokens(
            pid,
            address(this)
        );
        require(
            DexLibrary.checkSwapPairCompatibility(
                IPair(swapPair),
                WAVAXToken,
                extraRewardToken
            ),
            "_swapPairWAVAXJoe is not a WAVAX-extra reward pair, check masterChef.pendingTokens"
        );
        swapPairExtraToken = swapPair;
        extraToken == IPair(swapPairExtraToken).token0();
        if (IPair(swapPairExtraToken).token0() == WAVAXToken) {
            extraToken == IPair(swapPairExtraToken).token1();
        }
    }

    function _depositMasterchef(uint256 _pid, uint256 _amount)
        internal
        override
    {
        IERC20(swapPairJoeWavax).approve(
            address(masterChef),
            type(uint256).max
        );
        masterChef.deposit(_pid, _amount);
    }

    function _withdrawMasterchef(uint256 _pid, uint256 _amount)
        internal
        override
    {
        masterChef.withdraw(_pid, _amount);
    }

    function _emergencyWithdraw(uint256 _pid) internal override {
        masterChef.emergencyWithdraw(_pid);
    }

    function _convertRewardIntoWAVAX(
        uint256 pendingJoe,
        address extraRewardToken,
        uint256 pendingExtraReward
    ) private returns (uint256) {
        uint256 convertedAmountWAVAX = 0;

        if (extraRewardToken == joeToken) {
            convertedAmountWAVAX = DexLibrary.swap(
                pendingExtraReward.add(pendingJoe),
                joeToken,
                WAVAXToken,
                IPair(swapPairJoeWavax)
            );
            return convertedAmountWAVAX;
        }

        convertedAmountWAVAX = DexLibrary.swap(
            pendingJoe,
            joeToken,
            WAVAXToken,
            IPair(swapPairJoeWavax)
        );
        if (
            swapPairExtraToken != address(0) &&
            pendingExtraReward > 0 &&
            DexLibrary.checkSwapPairCompatibility(
                IPair(swapPairExtraToken),
                extraRewardToken,
                WAVAXToken
            )
        ) {
            convertedAmountWAVAX = convertedAmountWAVAX.add(
                DexLibrary.swap(
                    pendingExtraReward,
                    extraRewardToken,
                    WAVAXToken,
                    IPair(swapPairExtraToken)
                )
            );
        }
        return convertedAmountWAVAX;
    }

    function _pendingRewards(uint256 _pid, address _user)
        internal
        view
        override
        returns (uint256)
    {
        (
            uint256 pendingJoe,
            address extraRewardToken,
            ,
            uint256 pendingExtraToken
        ) = masterChef.pendingTokens(_pid, _user);
        uint256 poolRewardBalance = IERC20(joeToken).balanceOf(address(this));
        uint256 extraRewardTokenBalance;
        if (extraRewardToken != address(0)) {
            extraRewardTokenBalance = IERC20(extraRewardToken).balanceOf(
                address(this)
            );
        }
        uint256 rewardTokenBalance = IERC20(joeToken).balanceOf(address(this));

        uint256 estimatedWAVAX = DexLibrary.estimateConversionThroughPair(
            poolRewardBalance.add(pendingJoe),
            joeToken,
            WAVAXToken,
            IPair(swapPairJoeWavax)
        );
        if (
            address(swapPairExtraToken) != address(0) &&
            extraRewardTokenBalance.add(pendingExtraToken) > 0 &&
            DexLibrary.checkSwapPairCompatibility(
                IPair(swapPairExtraToken),
                extraRewardToken,
                WAVAXToken
            )
        ) {
            estimatedWAVAX.add(
                DexLibrary.estimateConversionThroughPair(
                    extraRewardTokenBalance.add(pendingExtraToken),
                    extraRewardToken,
                    WAVAXToken,
                    IPair(swapPairExtraToken)
                )
            );
        }
        return estimatedWAVAX;
    }

    function _getRewards(uint256 _pid) internal override {
        masterChef.deposit(_pid, 0);
        uint256 joeAmount = IERC20(joeToken).balanceOf(address(this));
        uint256 bonusAmount = 0;
        if (extraToken != address(0)) {
            bonusAmount = IERC20(extraToken).balanceOf(address(this));
        }
        _convertRewardIntoWAVAX(joeAmount, extraToken, bonusAmount);
    }

    function _userInfo(uint256 pid, address user)
        internal
        view
        override
        returns (uint256 amount, uint256 rewardDebt)
    {
        return masterChef.userInfo(pid, user);
    }

    function _getDepositFee(uint256 pid)
        internal
        view
        override
        returns (uint256)
    {
        return 0;
    }

    function _getWithdrawFee(uint256 pid)
        internal
        view
        override
        returns (uint256)
    {
        return 0;
    }

    function _bip() internal view override returns (uint256) {
        return 10000;
    }
}
