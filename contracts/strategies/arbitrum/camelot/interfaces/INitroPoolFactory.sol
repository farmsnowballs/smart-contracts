// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface INitroPoolFactory {
    function nftPoolPublishedNitroPoolsLength(address nftPoolAddress) external view returns (uint256);

    function getNftPoolPublishedNitroPool(address nftPoolAddress, uint256 index) external view returns (address);
}
