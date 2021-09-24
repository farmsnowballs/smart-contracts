// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IYakStrategy {
    function depositToken() external view returns (address);
    function depositFor(address account, uint amount) external;
    function withdraw(uint amount) external;
}