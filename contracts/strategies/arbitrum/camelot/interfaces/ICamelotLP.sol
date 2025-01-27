// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ICamelotLP {
    function token0FeePercent() external view returns (uint256);

    function token1FeePercent() external view returns (uint256);
}
