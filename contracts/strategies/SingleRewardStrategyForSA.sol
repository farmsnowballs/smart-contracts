// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";
import "./SingleRewardStrategy.sol";

/**
 * @notice Adapter strategy for SingleRewardStrategy with SA deposit.
 */
abstract contract SingleRewardStrategyForSA is SingleRewardStrategy {
    address private immutable swapPairDepositToken;

    constructor(
        address _swapPairDepositToken,
        SingleRewardStrategySettings memory _settings,
        StrategySettings memory _strategySettings
    ) SingleRewardStrategy(_settings, _strategySettings) {
        swapPairDepositToken = _swapPairDepositToken;
        assignSwapPairSafely(_swapPairDepositToken);
    }

    function assignSwapPairSafely(address _swapPairDepositToken) internal virtual {
        if (address(rewardToken) != address(depositToken)) {
            require(
                DexLibrary.checkSwapPairCompatibility(
                    IPair(_swapPairDepositToken),
                    address(depositToken),
                    address(rewardToken)
                ),
                "SingleRewardStrategyForSA::swapPairDepositToken does not match deposit and reward token"
            );
        }
    }

    function _convertRewardTokenToDepositToken(uint256 fromAmount)
        internal
        virtual
        override
        returns (uint256 toAmount)
    {
        if (address(rewardToken) == address(depositToken)) {
            return fromAmount;
        }
        return DexLibrary.swap(fromAmount, address(rewardToken), address(depositToken), IPair(swapPairDepositToken));
    }
}
