// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IFactory {
    function mint(address _gauge) external;
    function minted(address _user, address _gauge) external view returns (uint256);
    function is_valid_gauge(address _gauge) external view returns (bool);
}
