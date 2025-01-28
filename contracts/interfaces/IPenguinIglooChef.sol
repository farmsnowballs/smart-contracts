// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IPenguinIglooChef {
    function pefi() external view returns (address);
    function pefiEmissionPerSecond() external view returns (uint256);

    function poolLength() external view returns (uint256);
    function pendingPEFI(uint256 _pid, address _user) external view returns (uint256);
    function updatePool(uint256 _pid) external;
    function deposit(uint256 _pid, uint256 _amount, address to) external;
    function withdraw(uint256 _pid, uint256 _amount, address to) external;
    function userShares(uint256 pid, address user) external view returns(uint256);
    function poolInfo(uint pid) external view returns (
        address poolToken, // Address of LP token contract.
        address rewarder, // Address of rewarder for pool
        address strategy, // Address of strategy for pool
        uint256 allocPoint, // How many allocation points assigned to this pool. PEFIs to distribute per block.
        uint256 lastRewardTime, // Last block number that PEFIs distribution occurs.
        uint256 accPEFIPerShare, // Accumulated PEFIs per share, times ACC_PEFI_PRECISION. See below.
        uint16 withdrawFeeBP, // Withdrawal fee in basis points
        uint256 totalShares, //total number of shares in the pool
        uint256 lpPerShare //number of LP tokens per share, times ACC_PEFI_PRECISION
    );
    function userInfo(uint pid, address user) external view returns (
        uint256 amount,
        uint256 rewardDebt
    );
    function setIpefiDistributionBips(uint256 _ipefiDistributionBips) external;
    function emergencyWithdraw(uint256 pid, address to) external;
    function harvest(uint256 pid, address to) external;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
}