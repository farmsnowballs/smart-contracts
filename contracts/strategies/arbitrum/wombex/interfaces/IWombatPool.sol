// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IWombatPool {
    function deposit(address token, uint256 amount, uint256 minLiq, address to, uint256 deadline, bool shouldStake)
        external
        returns (uint256);

    function withdraw(address token, uint256 liquidity, uint256 minimumAmount, address to, uint256 deadline)
        external
        returns (uint256);

    function quotePotentialWithdraw(address token, uint256 liquidity) external view returns (uint256, uint256);

    function quotePotentialDeposit(address token, uint256 amount) external view returns (uint256, uint256);

    function mintFee(address token) external returns (uint256 feeCollected);
}
