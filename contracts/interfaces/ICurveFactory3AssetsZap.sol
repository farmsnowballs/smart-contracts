// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

interface ICurveFactory3AssetsZap {
    function calc_token_amount(uint256[3] memory _amounts, bool _is_deposit) external view returns (uint256);

    function add_liquidity(uint256[3] memory _amounts, uint256 _min_mint_amount) external;
}
