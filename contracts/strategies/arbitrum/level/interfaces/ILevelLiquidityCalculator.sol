// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ILevelLiquidityCalculator {
    function calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        external
        view
        returns (uint256 outAmountAfterFee, uint256 feeAmount);

    function calcAddRemoveLiquidityFee(address _token, uint256 _tokenPrice, uint256 _valueChange, bool _isAdd)
        external
        view
        returns (uint256);
}
