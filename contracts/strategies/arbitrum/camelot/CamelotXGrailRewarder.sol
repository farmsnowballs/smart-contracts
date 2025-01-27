// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../lib/Ownable.sol";
import "../../../lib/SafeERC20.sol";

/**
 * @title CamelotXGrailRewarder
 * @author Yield Yak
 * @notice CamelotXGrailRewarder is based on YyStaking
 */
contract CamelotXGrailRewarder is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Info of each user
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    /**
     * @notice We do some fancy math here. Basically, any point in time, the amount of deposit tokens
     * entitled to a user but is pending to be distributed is:
     *
     *   pending reward = (user.amount * accRewardPerShare) - user.rewardDebt[token]
     *
     * Whenever a user deposits or withdraws. Here's what happens:
     *   1. accRewardPerShare (and `lastRewardBalance`) gets updated
     *   2. User receives the pending reward sent to his/her address
     *   3. User's `amount` gets updated
     *   4. User's `rewardDebt[token]` gets updated
     */

    /// @dev Internal balance of depositToken, this gets updated on user deposits / withdrawals
    /// this allows to reward users with depositToken
    uint256 public internalBalance;

    /// @notice Array of tokens that users can claim
    IERC20 public rewardToken;

    /// @notice Last reward balance of `reward token`
    uint256 public lastRewardBalance;

    /// @notice Accumulated `token` rewards per share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    uint256 public accRewardPerShare;
    /// @notice The precision of `accRewardPerShare`
    uint256 public ACC_REWARD_PER_SHARE_PRECISION;

    /// @dev Info of each user that stakes
    mapping(address => UserInfo) private userInfo;

    /// @notice Emitted when a user deposits
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims reward
    event ClaimReward(address indexed user, address indexed rewardToken, uint256 amount);

    constructor(IERC20 _rewardToken, address _owner) {
        require(address(_rewardToken) != address(0), "YyStaking::rewardToken can't be address(0)");
        rewardToken = _rewardToken;
        ACC_REWARD_PER_SHARE_PRECISION = 1e24;
        transferOwnership(_owner);
    }

    /**
     * @notice Deposit on behalf of another account
     * @param _account Account to deposit for
     * @param _amount The amount of depositToken to deposit
     */
    function depositFor(address _account, uint256 _amount) external onlyOwner returns (uint256) {
        UserInfo storage user = userInfo[_account];

        uint256 _previousAmount = user.amount;
        uint256 _newAmount = user.amount + _amount;
        user.amount = _newAmount;

        updateReward();

        uint256 _previousRewardDebt = user.rewardDebt;
        user.rewardDebt = (_newAmount * accRewardPerShare) / (ACC_REWARD_PER_SHARE_PRECISION);

        uint256 claimed;
        if (_previousAmount != 0) {
            claimed = ((_previousAmount * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - _previousRewardDebt;
            if (claimed != 0) {
                safeTokenTransfer(rewardToken, msg.sender, claimed);
                emit ClaimReward(_account, address(rewardToken), claimed);
            }
        }

        internalBalance = internalBalance + _amount;
        emit Deposit(_account, _amount);
        return claimed;
    }

    /**
     * @notice Get user info
     * @param _user The address of the user
     * @return The amount of depositToken user has deposited
     * @return The reward debt
     */
    function getUserInfo(address _user) external view returns (uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        return (user.amount, user.rewardDebt);
    }

    /**
     * @notice View function to see pending reward token on frontend
     * @param _user The address of the user
     * @return `_user`'s pending reward token
     */
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 _totalDepositTokens = internalBalance;
        uint256 _accRewardTokenPerShare = accRewardPerShare;

        uint256 _currRewardBalance = rewardToken.balanceOf(address(this));

        if (_currRewardBalance != lastRewardBalance && _totalDepositTokens != 0) {
            uint256 _accruedReward = _currRewardBalance - lastRewardBalance;
            _accRewardTokenPerShare =
                _accRewardTokenPerShare + ((_accruedReward * ACC_REWARD_PER_SHARE_PRECISION) / _totalDepositTokens);
        }
        return ((user.amount * _accRewardTokenPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;
    }

    /**
     * @notice Withdraw and harvest the rewards
     * @param _amount The amount to withdraw
     */
    function withdrawFor(address _account, uint256 _amount) external onlyOwner returns (uint256) {
        UserInfo storage user = userInfo[_account];
        uint256 _previousAmount = user.amount;
        require(_amount <= _previousAmount, "YyStaking::withdraw amount exceeds balance");
        uint256 _newAmount = user.amount - _amount;
        user.amount = _newAmount;

        uint256 claimed;
        if (_previousAmount != 0) {
            updateReward();

            claimed = ((_previousAmount * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;
            user.rewardDebt = (_newAmount * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;

            if (claimed != 0) {
                safeTokenTransfer(rewardToken, msg.sender, claimed);
                emit ClaimReward(_account, address(rewardToken), claimed);
            }
        }

        internalBalance = internalBalance - _amount;
        emit Withdraw(_account, _amount);
        return claimed;
    }

    /**
     * @notice Update reward variables
     * @dev Needs to be called before any deposit or withdrawal
     */
    function updateReward() public {
        uint256 _totalDepositTokens = internalBalance;

        uint256 _currRewardBalance = rewardToken.balanceOf(address(this));

        // Did YyStaking receive any token
        if (_currRewardBalance == lastRewardBalance || _totalDepositTokens == 0) {
            return;
        }

        uint256 _accruedReward = _currRewardBalance - lastRewardBalance;

        accRewardPerShare =
            accRewardPerShare + ((_accruedReward * ACC_REWARD_PER_SHARE_PRECISION) / _totalDepositTokens);
        lastRewardBalance = _currRewardBalance;
    }

    /**
     * @notice Safe token transfer function, just in case if rounding error
     * causes pool to not have enough reward tokens
     * @param _token The address of then token to transfer
     * @param _to The address that will receive `_amount` `rewardToken`
     * @param _amount The amount to send to `_to`
     */
    function safeTokenTransfer(IERC20 _token, address _to, uint256 _amount) internal {
        uint256 _currRewardBalance = _token.balanceOf(address(this));

        if (_amount > _currRewardBalance) {
            lastRewardBalance = lastRewardBalance - _currRewardBalance;
            _token.safeTransfer(_to, _currRewardBalance);
        } else {
            lastRewardBalance = lastRewardBalance - _amount;
            _token.safeTransfer(_to, _amount);
        }
    }
}
