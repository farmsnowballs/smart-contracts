// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IBaseStrategy {
    struct BaseStrategySettings {
        address gasToken;
        address[] rewards;
        address simpleRouter;
    }

    struct Reward {
        address reward;
        uint256 amount;
    }
}
