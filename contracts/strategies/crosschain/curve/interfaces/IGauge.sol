// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IGauge {
    function reward_tokens(uint256 _index) external view returns (address);
    function claimable_reward(address _user, address _token) external view returns (uint256);
    function reward_count() external view returns (uint256);
    function balanceOf(address _user) external view returns (uint256);
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
    function factory() external view returns (address);
    function claim_rewards() external;

    function period() external view returns (uint256);
    function period_timestamp(uint256 _period) external view returns (uint256);
    function integrate_inv_supply(uint256 _period) external view returns (uint256);
    function integrate_inv_supply_of(address _user) external view returns (uint256);
    function working_supply() external view returns (uint256);
    function working_balances(address _user) external view returns (uint256);
    function inflation_rate(uint256 _period) external view returns (uint256);
    function integrate_fraction(address _user) external view returns (uint256);
}
