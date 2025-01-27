// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ICamelotVoter {
    function execute(address to, uint256 value, bytes calldata data) external returns (bool, bytes memory);

    function wrapEthBalance() external returns (uint256);

    function mint(address _receiver) external;

    function burn(address _account, uint256 _amount) external;

    function xGrailForYYGrail(uint256 amount) external view returns (uint256);

    function unallocatedXGrail() external view returns (uint256);

    function allocatedXGrail() external view returns (uint256);

    function setVoterProxy(address _voterProxy) external;
}
