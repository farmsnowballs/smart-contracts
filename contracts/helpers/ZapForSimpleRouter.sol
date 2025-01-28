// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../lib/Ownable.sol";
import "../lib/SafeERC20.sol";
import "./../interfaces/ISimpleRouter.sol";
import "./../interfaces/IYakStrategy.sol";

contract ZapForSimpleRouter is Ownable {
    using SafeERC20 for IERC20;

    address public immutable simpleRouter;

    event Recovered(address token, uint256 amount);

    constructor(
        address _simpleRouter
    ) {
        simpleRouter = _simpleRouter;
    }

    function _swap(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _minAmountOut) internal returns (uint256) {
        IERC20(_tokenIn).approve(simpleRouter, _amountIn);
        FormattedOffer memory trade = ISimpleRouter(simpleRouter).query(_amountIn, _tokenIn, _tokenOut);
        uint256 amountOut = ISimpleRouter(simpleRouter).swap(trade);
        require(amountOut > _minAmountOut, "ZapForSimpleRouter::amountOut too low");
        return amountOut;
    }

    function swap(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _minAmountOut) external returns (uint256) {
        return _swap(_tokenIn, _amountIn, _tokenOut, _minAmountOut);
    }

    function zapIn(address _strategy, address _tokenIn, uint256 _amountIn, uint256 _minAmountOut) external {
        // Swap
        address depositToken = IYakStrategy(_strategy).depositToken();
        uint256 amountOut = _swap(_tokenIn, _amountIn, depositToken, _minAmountOut);

        // Deposit
        IERC20(depositToken).approve(_strategy, amountOut);
        IYakStrategy(_strategy).depositFor(msg.sender, amountOut);
    }

    function zapOut(address _strategy, address _tokenOut, uint256 _sharesOut, uint256 _minAmountOut) external {
        // Transfer shares
        require(IERC20(_strategy).transferFrom(msg.sender, address(this), _sharesOut), "ZapForSimpleRouter::transferFrom failed");

        // Withdraw
        address depositToken = IYakStrategy(_strategy).depositToken();
        uint256 balanceBefore = IERC20(depositToken).balanceOf(address(this));
        IYakStrategy(_strategy).withdraw(_sharesOut);
        uint256 balanceAfter = IERC20(depositToken).balanceOf(address(this));
        uint256 amountIn = balanceAfter - balanceBefore;
        require(amountIn > 0, "ZapForSimpleRouter::amountIn too low");

        // Swap
        uint256 amountOut = _swap(depositToken, amountIn, _tokenOut, _minAmountOut);

        // Transfer
        require(IERC20(_tokenOut).transfer(msg.sender, amountOut), "ZapForSimpleRouter::transfer failed");

    }

    /**
     * @notice Recover ERC20 from contract
     * @param tokenAddress token address
     * @param tokenAmount amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAmount > 0);
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /**
     * @notice Recover GAS from contract
     * @param amount amount
     */
    function recoverGas(uint256 amount) external onlyOwner {
        require(amount > 0);
        payable(msg.sender).transfer(amount);
        emit Recovered(address(0), amount);
    }
}