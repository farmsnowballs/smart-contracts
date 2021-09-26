// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

// https://github.com/Benqi-fi/BENQI-Smart-Contracts/blob/master/staking/PglStakingContract.sol
interface IBenqiStakingContract {
    function supplyAmount(address) external view returns (uint);
    function deposit(uint pglAmount) external;
    function redeem(uint pglAmount) external;
    function claimRewards() external;
    function getClaimableRewards(uint rewardToken) external view returns (uint);
}