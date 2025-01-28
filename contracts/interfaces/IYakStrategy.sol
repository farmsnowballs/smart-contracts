// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IYakStrategy {
    function depositToken() external view returns (address);

    function depositFor(address account, uint256 amount) external;

    function withdraw(uint256 _amount) external;
}
