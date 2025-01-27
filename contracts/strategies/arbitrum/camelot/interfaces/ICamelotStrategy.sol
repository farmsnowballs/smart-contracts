// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ICamelotStrategy {
    function pool() external view returns (address);

    function positionId() external view returns (uint256);

    function claimReward() external;
}
