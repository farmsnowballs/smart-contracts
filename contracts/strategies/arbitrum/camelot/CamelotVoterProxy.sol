// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../lib/SafeERC20.sol";
import "./../../VariableRewardsStrategy.sol";
import "./interfaces/ICamelotVoter.sol";
import "./interfaces/ICamelotVoterProxy.sol";
import "./interfaces/INFTPool.sol";
import "./interfaces/ICamelotStrategy.sol";
import "./interfaces/IXGrail.sol";
import "./interfaces/INitroPool.sol";
import "./interfaces/INitroPoolFactory.sol";

library SafeProxy {
    function safeExecute(
        ICamelotVoter voter,
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnValue) = voter.execute(target, value, data);
        if (!success) revert("PlatypusVoterProxy::safeExecute failed");
        return returnValue;
    }
}

/**
 * @notice PlatypusVoterProxy is an upgradable contract.
 * Strategies interact with PlatypusVoterProxy and
 * PlatypusVoterProxy interacts with PlatypusVoter.
 * @dev For accounting reasons, there is one approved
 * strategy per Masterchef PID. In case of upgrade,
 * use a new proxy.
 */
contract CamelotVoterProxy is ICamelotVoterProxy {
    using SafeProxy for ICamelotVoter;
    using SafeERC20 for IERC20;

    struct Reward {
        address reward;
        uint256 amount;
    }

    uint256 internal constant TOTAL_REWARDS_SHARES = 10000;
    uint256 internal constant BIPS_DIVISOR = 10000;
    uint256 internal constant POSITION_INIT_AMOUNT = 1 wei;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant GRAIL = 0x3d9907F9a368ad0a51Be60f7Da3b97cf940982D8;
    address internal constant xGRAIL = 0x3CAaE25Ee616f2C8E13C74dA0813402eae3F496b;
    address internal constant NITRO_POOL_FACTORY = 0xe0a6b372Ac6AF4B37c7F3a989Fe5d5b194c24569;

    ICamelotVoter public immutable voter;
    // address public immutable yieldBooster;

    address public devAddr;
    // pool => position id => strategy
    mapping(address => mapping(uint256 => address)) public approvedStrategies;

    modifier onlyDev() {
        require(msg.sender == devAddr, "PlatypusVoterProxy::onlyDev");
        _;
    }

    modifier onlyStrategy(address _pool, uint256 _positionId) {
        require(approvedStrategies[_pool][_positionId] == msg.sender, "CamelotVoterProxy:onlyStrategy");
        _;
    }

    constructor(address _voter, address _devAddr) {
        devAddr = _devAddr;
        voter = ICamelotVoter(_voter);
    }

    /**
     * @notice Update devAddr
     * @param _newValue address
     */
    function updateDevAddr(address _newValue) external onlyDev {
        devAddr = _newValue;
    }

    function createPosition(
        address _nftPool,
        address _lpToken,
        bool _useNitroPool,
        uint256 _nitroPoolIndex
    ) external onlyDev returns (uint256) {
        IERC20(_lpToken).safeTransferFrom(msg.sender, address(voter), POSITION_INIT_AMOUNT);
        voter.safeExecute(_lpToken, 0, abi.encodeWithSelector(IERC20.approve.selector, _nftPool, POSITION_INIT_AMOUNT));
        voter.safeExecute(
            _nftPool,
            0,
            abi.encodeWithSelector(INFTPool.createPosition.selector, POSITION_INIT_AMOUNT, 0)
        );
        uint256 positionId = INFTPool(_nftPool).lastTokenId();
        if (_useNitroPool) {
            _stakeInNitroPool(positionId, _nftPool, _nitroPoolIndex);
        }
        return positionId;
    }

    function _stakeInNitroPool(
        uint256 _positionId,
        address _nftPool,
        uint256 _nitroPoolIndex
    ) internal returns (address) {
        address nitroPool = INitroPoolFactory(NITRO_POOL_FACTORY).getNftPoolPublishedNitroPool(
            _nftPool,
            _nitroPoolIndex
        );
        voter.safeExecute(
            _nftPool,
            0,
            abi.encodeWithSelector(INFTPool.safeTransferFrom.selector, address(voter), nitroPool, _positionId)
        );
        return nitroPool;
    }

    // /**
    //  * @notice Add an approved strategy
    //  * @dev Very sensitive, restricted to devAddr
    //  * @dev Can only be set once per position id and pool (reported by the strategy)
    //  * @param _strategy address
    //  */
    function approveStrategy(address _strategy) public onlyDev {
        uint256 positionId = ICamelotStrategy(_strategy).positionId();
        address pool = ICamelotStrategy(_strategy).pool();
        require(
            approvedStrategies[pool][positionId] == address(0),
            "CamelotVoterProxy::Strategy for position id already added"
        );
        approvedStrategies[pool][positionId] = _strategy;
    }

    function updateNitroPool(
        uint256 _positionId,
        address _nitroPool,
        address _nftPool,
        bool _useNewNitroPool,
        uint256 _nitroPoolIndex
    ) external onlyStrategy(_nftPool, _positionId) returns (address nitroPool) {
        if (_nitroPool > address(0)) {
            voter.safeExecute(_nitroPool, 0, abi.encodeWithSelector(INitroPool.withdraw.selector, _positionId));
        }

        if (_useNewNitroPool) return _stakeInNitroPool(_positionId, _nftPool, _nitroPoolIndex);
    }

    /**
     * @notice Deposit function
     * @param _positionId ERC721 token id / position id
     * @param _nftPool Staking contract
     * @param _lpToken LP token
     * @param _amount deposit amount
     */
    function deposit(
        uint256 _positionId,
        address _nftPool,
        address _lpToken,
        uint256 _amount
    ) external onlyStrategy(_nftPool, _positionId) {
        voter.safeExecute(_lpToken, 0, abi.encodeWithSelector(IERC20.approve.selector, _nftPool, _amount));
        voter.safeExecute(_nftPool, 0, abi.encodeWithSelector(INFTPool.addToPosition.selector, _positionId, _amount));
    }

    /**
     * @notice Withdraw function
     * @dev Restricted to strategy with _pid
     * @param _positionId ERC721 token id / position id
     * @param _nftPool Staking contract
     * @param _lpToken LP token
     * @param _amount withdraw amount
     */
    function withdraw(
        uint256 _positionId,
        address _nftPool,
        address _nitroPool,
        address _lpToken,
        uint256 _amount
    ) external onlyStrategy(_nftPool, _positionId) {
        if (_nitroPool > address(0)) {
            voter.safeExecute(_nitroPool, 0, abi.encodeWithSelector(INitroPool.withdraw.selector, _positionId));
        }
        voter.safeExecute(
            _nftPool,
            0,
            abi.encodeWithSelector(INFTPool.withdrawFromPosition.selector, _positionId, _amount)
        );
        voter.safeExecute(_lpToken, 0, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, _amount));
        if (_nitroPool > address(0)) {
            voter.safeExecute(
                _nftPool,
                0,
                abi.encodeWithSelector(INFTPool.safeTransferFrom.selector, address(voter), _nitroPool, _positionId)
            );
        }
    }

    /**
     * @notice Emergency withdraw function
     * @dev Restricted to strategy with _pid
     * @param _positionId ERC721 token id / position id
     * @param _nftPool Staking contract
     * @param _lpToken LP token
     */
    function emergencyWithdraw(
        uint256 _positionId,
        address _nftPool,
        address _nitroPool,
        address _lpToken
    ) external onlyStrategy(_nftPool, _positionId) {
        if (_nitroPool > address(0)) {
            voter.safeExecute(_nitroPool, 0, abi.encodeWithSelector(INitroPool.withdraw.selector, _positionId));
        }
        voter.safeExecute(_nftPool, 0, abi.encodeWithSelector(INFTPool.emergencyWithdraw.selector, _positionId));
        uint256 balance = IERC20(_lpToken).balanceOf(address(voter));
        voter.safeExecute(_lpToken, 0, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, balance));
    }

    function pendingRewards(
        uint256 _positionId,
        address _nftPool,
        address _nitroPool
    ) external view returns (VariableRewardsStrategy.Reward[] memory) {
        uint256 pendingTotal = INFTPool(_nftPool).pendingRewards(_positionId);
        uint256 xGrailRewards = (pendingTotal * INFTPool(_nftPool).xGrailRewardsShare()) / TOTAL_REWARDS_SHARES;
        uint256 pendingGrail = pendingTotal - xGrailRewards;
        (
            address token1,
            address token2,
            uint256 pending1,
            uint256 pending2,
            uint256 nitroPendingGrail,
            uint256 pendingCount
        ) = pendingNitroRewards(_nitroPool);
        VariableRewardsStrategy.Reward[] memory rewards = new VariableRewardsStrategy.Reward[](pendingCount + 1);
        rewards[0] = VariableRewardsStrategy.Reward({reward: address(GRAIL), amount: pendingGrail + nitroPendingGrail});
        if (pending1 > 0) {
            rewards[1] = VariableRewardsStrategy.Reward({reward: token1, amount: pending1});
        }
        if (pending2 > 0) {
            rewards[rewards.length - 1] = VariableRewardsStrategy.Reward({reward: token2, amount: pending2});
        }
        return rewards;
    }

    function pendingNitroRewards(address _nitroPool)
        internal
        view
        returns (
            address token1,
            address token2,
            uint256 pending1,
            uint256 pending2,
            uint256 pendingGrail,
            uint256 pendingCount
        )
    {
        if (_nitroPool > address(0)) {
            (pending1, pending2) = INitroPool(_nitroPool).pendingRewards(address(voter));
            if (pending1 > 0) {
                token1 = INitroPool(_nitroPool).rewardsToken1();
                if (token1 == xGRAIL) {
                    pending1 = 0;
                } else if (token1 == GRAIL) {
                    pendingGrail = pending1;
                    pending1 = 0;
                } else {
                    pendingCount++;
                }
            }
            if (pending2 > 0) {
                token2 = INitroPool(_nitroPool).rewardsToken2();
                if (token2 == xGRAIL) {
                    pending2 = 0;
                } else if (token2 == GRAIL) {
                    pendingGrail = pending2;
                    pending2 = 0;
                } else {
                    pendingCount++;
                }
            }
        }
    }

    /**
     * @notice Pool balance
     * @param _nftPool Staking contract
     * @param _positionId ERC721 token id / position id
     * @return balance in depositToken
     */
    function poolBalance(uint256 _positionId, address _nftPool) external view returns (uint256 balance) {
        (balance, , , , , , , ) = INFTPool(_nftPool).getStakingPosition(_positionId);
        if (balance >= POSITION_INIT_AMOUNT) {
            balance = balance - POSITION_INIT_AMOUNT;
        }
    }

    /**
     * @notice Claim and distribute PTP rewards
     * @dev Restricted to strategy with _pid
     * @param _positionId ERC721 token id / position id
     * @param _nftPool Staking contract
     */
    function claimReward(
        uint256 _positionId,
        address _nftPool,
        address _nitroPool
    ) external onlyStrategy(_nftPool, _positionId) {
        (address token1, address token2, uint256 claimed1, uint256 claimed2) = claimNitroRewards(_nitroPool);
        if (claimed1 > 0) {
            voter.safeExecute(token1, 0, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, claimed1));
        }
        if (claimed2 > 0) {
            voter.safeExecute(token2, 0, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, claimed2));
        }
        voter.safeExecute(_nftPool, 0, abi.encodeWithSelector(INFTPool.harvestPosition.selector, _positionId));
        uint256 balance = IERC20(GRAIL).balanceOf(address(voter));
        voter.safeExecute(GRAIL, 0, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, balance));

        uint256 unallocatedXGrail = voter.unallocatedXGrail();
        if (unallocatedXGrail > 0) {
            address yieldBooster = INFTPool(_nftPool).yieldBooster();
            bytes memory data = abi.encode(_nftPool, _positionId);
            voter.safeExecute(
                xGRAIL,
                0,
                abi.encodeWithSelector(IXGrail.approveUsage.selector, yieldBooster, unallocatedXGrail)
            );
            voter.safeExecute(
                xGRAIL,
                0,
                abi.encodeWithSelector(IXGrail.allocate.selector, yieldBooster, unallocatedXGrail, data)
            );
        }
    }

    function claimNitroRewards(address _nitroPool)
        internal
        returns (
            address token1,
            address token2,
            uint256 claimed1,
            uint256 claimed2
        )
    {
        if (_nitroPool > address(0)) {
            voter.safeExecute(_nitroPool, 0, abi.encodeWithSelector(INitroPool.harvest.selector));
            token1 = INitroPool(_nitroPool).rewardsToken1();
            if (token1 == xGRAIL || token1 == GRAIL) {
                claimed1 = 0;
            } else {
                claimed1 = IERC20(token1).balanceOf(address(voter));
            }
            token2 = INitroPool(_nitroPool).rewardsToken2();
            if (token2 == xGRAIL || token2 == GRAIL) {
                claimed2 = 0;
            } else {
                claimed2 = IERC20(token2).balanceOf(address(voter));
            }
        }
    }
}
