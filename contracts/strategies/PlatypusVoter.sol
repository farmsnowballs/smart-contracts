// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../interfaces/IWAVAX.sol";
import "../interfaces/IVePTP.sol";
import "../lib/SafeERC20.sol";
import "../lib/Ownable.sol";

contract PlatypusVoter is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    address public constant PTP = address(0x22d4002028f537599bE9f666d1c4Fa138522f9c8);
    IVePTP public constant vePTP = IVePTP(0x5857019c749147EEE22b1Fe63500F237F3c1B692);

    string public constant name = "PlatypusVoter";
    address public immutable devAddr;
    address public voterProxy;

    modifier onlyPlatypusVoterProxy() {
        require(msg.sender == voterProxy, "PlatypusVoter::onlyPlatypusVoterProxy");
        _;
    }

    modifier onlyPlatypusVoterProxyOrDev() {
        require(msg.sender == voterProxy || msg.sender == devAddr, "PlatypusVoter:onlyPlatypusVoterProxyOrDev");
        _;
    }

    constructor(address _timelock, address _devAddr) {
        devAddr = _devAddr;
        transferOwnership(_timelock);
    }

    receive() external payable {}

    function balanceOf() public view returns (uint256) {
        return vePTP.balanceOf(address(this));
    }

    function setVoterProxy(address _voterProxy) external onlyOwner {
        voterProxy = _voterProxy;
    }

    function increaseStake(uint256 _value) external onlyPlatypusVoterProxyOrDev {
        IERC20(PTP).safeApprove(address(vePTP), _value);
        vePTP.deposit(_value);
        IERC20(PTP).safeApprove(address(vePTP), 0);
    }

    function unstake(uint256 _amount) external onlyOwner {
        vePTP.withdraw(_amount);
    }

    function claimVePTP() external onlyPlatypusVoterProxyOrDev {
        vePTP.claim();
    }

    function wrapAvaxBalance() external onlyPlatypusVoterProxy returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            WAVAX.deposit{value: balance}();
        }
        return balance;
    }

    function withdraw(uint256 _amount) external onlyPlatypusVoterProxy {
        IERC20(PTP).safeTransfer(voterProxy, _amount);
    }

    function withdrawAll() external onlyPlatypusVoterProxy returns (uint256 balance) {
        balance = IERC20(PTP).balanceOf(address(this));
        IERC20(PTP).safeTransfer(voterProxy, balance);
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyPlatypusVoterProxy returns (bool, bytes memory) {
        (bool success, bytes memory result) = target.call{value: value}(data);

        return (success, result);
    }
}
