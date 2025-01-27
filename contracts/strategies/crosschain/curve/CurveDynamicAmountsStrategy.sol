// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CurveStrategy.sol";

contract CurveDynamicAmountsStrategy is CurveStrategy {
    constructor(
        CurveStrategySettings memory _curveStrategySettings,
        BaseStrategySettings memory _baseStrategySettings,
        StrategySettings memory _strategySettings
    ) CurveStrategy(_curveStrategySettings, _baseStrategySettings, _strategySettings) {}

    function _addLiquidity(uint256 _amountIn) internal override returns (uint256 amountOut) {
        uint256[] memory amounts = new uint256[](lpTokenCount);
        amounts[lpTokenInIndex] = _amountIn;

        return IPool(address(depositToken)).add_liquidity(amounts, 0);
    }
}
