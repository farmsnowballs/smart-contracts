// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../../../../interfaces/IBaseStrategy.sol";
import "./ICamelotVoter.sol";

interface ICamelotVoterProxy {
    function createPosition(address _nftPool, address _lpToken, bool _useNitroPool, uint256 _nitroPoolIndex)
        external
        returns (uint256);

    function updateNitroPool(
        uint256 _positionId,
        address _nitroPool,
        address _nftPool,
        bool _useNewNitroPool,
        uint256 _nitroPoolIndex
    ) external returns (address nitroPool);

    function deposit(uint256 _positionId, address _nftPool, address _lpToken, uint256 _amount) external;

    function withdraw(uint256 _positionId, address _nftPool, address _nitroPool, address _lpToken, uint256 _amount)
        external;

    function convertToXGrail(address _nftPool, uint256 _positionId, uint256 _amount, address _receiver) external;

    function emergencyWithdraw(uint256 _positionId, address _nftPool, address _nitroPool, address _lpToken) external;

    function pendingRewards(uint256 _positionId, address _nftPool, address _nitroPool)
        external
        view
        returns (IBaseStrategy.Reward[] memory);

    function poolBalance(uint256 _positionId, address _nftPool) external view returns (uint256 balance);

    function voter() external view returns (ICamelotVoter);

    function claimReward(uint256 _positionId, address _nftPool, address _nitroPool, address _yyGrailReceiver)
        external;
}
