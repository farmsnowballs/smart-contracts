// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../router/interfaces/IYakRouter.sol";

interface ISimpleRouter {
    error UnsupportedSwap(address _tokenIn, address _tokenOut);
    error SlippageExceeded();
    error InvalidConfiguration();

    struct SwapConfig {
        bool useYakSwapRouter;
        uint8 yakSwapMaxSteps;
        Path path;
    }

    struct Path {
        address[] adapters;
        address[] tokens;
    }

    function query(uint256 _amountIn, address _tokenIn, address _tokenOut)
        external
        view
        returns (FormattedOffer memory trade);

    function swap(FormattedOffer memory _trade) external returns (uint256 amountOut);
}
