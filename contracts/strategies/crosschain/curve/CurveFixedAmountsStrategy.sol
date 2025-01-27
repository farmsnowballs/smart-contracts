// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CurveStrategy.sol";

contract CurveFixedAmountsStrategy is CurveStrategy {
    constructor(
        CurveStrategySettings memory _curveStrategySettings,
        BaseStrategySettings memory _baseStrategySettings,
        StrategySettings memory _strategySettings
    ) CurveStrategy(_curveStrategySettings, _baseStrategySettings, _strategySettings) {
        require(lpTokenCount > 1 && lpTokenCount < 5, "CurveStrategy::Unsupported LP token");
    }

    function _addLiquidity(uint256 _amountIn) internal override returns (uint256 amountOut) {
        if (lpTokenCount == 2) {
            uint256[2] memory amounts;
            amounts[lpTokenInIndex] = _amountIn;

            return IPool(address(depositToken)).add_liquidity(amounts, 0);
        } else if (lpTokenCount == 3) {
            uint256[3] memory amounts;
            amounts[lpTokenInIndex] = _amountIn;

            return IPool(address(depositToken)).add_liquidity(amounts, 0);
        } else if (lpTokenCount == 4) {
            uint256[4] memory amounts;
            amounts[lpTokenInIndex] = _amountIn;

            return IPool(address(depositToken)).add_liquidity(amounts, 0);
        }
    }
}
