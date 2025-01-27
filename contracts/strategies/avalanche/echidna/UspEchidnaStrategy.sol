// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./EchidnaStrategy.sol";

contract UspEchidnaStrategy is EchidnaStrategy {
    address public constant USP = 0xdaCDe03d7Ab4D81fEDdc3a20fAA89aBAc9072CE2;
    IERC20 public constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);

    constructor(
        EchidnaStrategySettings memory _echidnaStrategySettings,
        VariableRewardsStrategySettings memory _variableRewardsStrategySettings,
        StrategySettings memory _strategySettings
    ) EchidnaStrategy(_echidnaStrategySettings, _variableRewardsStrategySettings, _strategySettings) {}

    function assignSwapPairSafely(address _swapPairDepositToken) internal override {}

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal override returns (uint256 toAmount) {
        // swap WAVAX to USDC
        WAVAX.approve(address(swapPairDepositToken), _fromAmount);
        uint256 usdcAmount = DexLibrary.swap(_fromAmount, address(WAVAX), address(USDC), IPair(swapPairDepositToken));
        WAVAX.approve(address(swapPairDepositToken), 0);

        // swap USDC to USP
        USDC.approve(address(platypusPool), usdcAmount);
        (toAmount, ) = platypusPool.swap(address(USDC), USP, usdcAmount, 0, address(this), type(uint256).max);
        USDC.approve(address(platypusPool), 0);
    }
}
