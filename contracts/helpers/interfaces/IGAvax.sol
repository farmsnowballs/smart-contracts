// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IGAvax {
    function pricePerShare(uint256 id) external view returns (uint256);
}
