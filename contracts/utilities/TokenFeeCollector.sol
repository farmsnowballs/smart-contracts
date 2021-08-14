// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../interfaces/IERC20.sol";
import "../lib/Ownable.sol";
import "../lib/SafeMath.sol";

contract TokenFeeCollector is Ownable {
    using SafeMath for uint;

    // this means 100% so 1000000 is 1%, 100000 is 0.1%, etc
    uint private constant maxBips = 100000000;

    struct TokenInfo {
        bool isValue;
        address[] payees;
        uint[] paymentBips;
    }

    mapping(address => TokenInfo) tokenPayees;

    constructor() Ownable() {}

    function registerToken(address tokenAddress, address devAddress, uint paymentBips) external onlyOwner {
        require(!tokenPayees[tokenAddress].isValue, "This token is registered");
        address[] memory _payees = new address[](1);
        uint[] memory _paymentBips = new uint[](1);
        _payees[0] = devAddress;
        _paymentBips[0] = paymentBips;
        TokenInfo memory tInfo = TokenInfo({
            payees: _payees,
            paymentBips: _paymentBips,
            isValue: true
        });
        tokenPayees[tokenAddress] = tInfo;
    }

    function addPayee(address tokenAddress, address devAddress, uint paymentBips) external onlyOwner {
        require(
            tokenPayees[tokenAddress].isValue,
            "This token is not registered, use registerToken to initialize it"
        );
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        for(uint i = 0; i < tInfo.payees.length; i++) {
            require(tInfo.payees[i] != devAddress, "This devAddress is already registered");
        }
        tInfo.payees.push(devAddress);
        tInfo.paymentBips.push(paymentBips);
    }

    function removePayee(address tokenAddress, address devAddress) external onlyOwner {
        require(
            tokenPayees[tokenAddress].isValue,
            "This token is not registered, use registerToken to initialize it"
        );
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        uint payeeIndex = tInfo.payees.length+1;
        for(uint i = 0; i < tInfo.payees.length; i++) {
            if (tInfo.payees[i] == devAddress) {
                payeeIndex = i;
                break;
            }
        }
        require(payeeIndex < tInfo.payees.length, "Payee not found");
        _removeElement(tokenAddress, payeeIndex);
    }

    function editPayee(address tokenAddress, address devAddress, uint paymentBips) external onlyOwner {
        require(
            tokenPayees[tokenAddress].isValue,
            "This token is not registered, use registerToken to initialize it"
        );
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        uint payeeIndex = tInfo.payees.length+1;
        for(uint i = 0; i < tInfo.payees.length; i++) {
            if (tInfo.payees[i] == devAddress) {
                payeeIndex = i;
                break;
            }
        }
        require(payeeIndex < tInfo.payees.length, "Payee not found");
        tInfo.paymentBips[payeeIndex] = paymentBips;
    }

    function viewPayee(address tokenAddress, uint index) external view onlyOwner returns(address, uint) {
        require(
            tokenPayees[tokenAddress].isValue,
            "The token is not registered, use registerToken to initialize it"
        );
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        require(index < tInfo.payees.length, "You're reading from outside the boundaries");
        return (tInfo.payees[index], tInfo.paymentBips[index]);
    }

    function collectFee(address tokenAddress) external {
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        uint payeeIndex = tInfo.payees.length+1;
        for(uint i = 0; i < tInfo.payees.length; i++) {
            if (tInfo.payees[i] == msg.sender) {
                payeeIndex = i;
                break;
            }
        }
        require(payeeIndex < tInfo.payees.length || msg.sender == owner(), "You're not a payee or the owner, don't collect");
        uint totalBips = 0;
        for(uint i = 0; i < tInfo.payees.length; i++) {
            totalBips += tInfo.paymentBips[i];
        }

        require(totalBips <= maxBips, "The total payout configured exceeds 100%, contact the feeCollect owner");
        uint balance = IERC20(tokenAddress).balanceOf(address(this));
        for(uint i = 0; i < tInfo.payees.length; i++) {
            address payee = tInfo.payees[i];
            uint paymentBips = tInfo.paymentBips[i];
            IERC20(tokenAddress).transfer(payee, balance.mul(paymentBips).div(maxBips));
        }
    }

    function viewBalance(address tokenAddress) external view returns (uint, uint) {
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        uint payeeIndex = tInfo.payees.length+1;
        for(uint i = 0; i < tInfo.payees.length; i++) {
            if (tInfo.payees[i] == msg.sender) {
                payeeIndex = i;
                break;
            }
        }

        uint balance = IERC20(tokenAddress).balanceOf(address(this));
        return (tInfo.paymentBips[payeeIndex], balance.mul(tInfo.paymentBips[payeeIndex]).div(maxBips));
    }

    function recoverToken(address tokenAddress) external onlyOwner {
        uint balance = IERC20(tokenAddress).balanceOf(address(this));
        require(balance > 0, "Not enough balance");
        IERC20(tokenAddress).transfer(msg.sender, balance);
    }

    function _removeElement(address tokenAddress, uint index) internal {
        TokenInfo storage tInfo = tokenPayees[tokenAddress];
        if (index >= tInfo.payees.length) return;

        for (uint i = index; i < tInfo.payees.length - 1; i++){
            tInfo.payees[i] = tInfo.payees[i+1];
            tInfo.paymentBips[i] = tInfo.paymentBips[i+1];
        }
        tInfo.payees.pop();
        tInfo.paymentBips.pop();
    }
}