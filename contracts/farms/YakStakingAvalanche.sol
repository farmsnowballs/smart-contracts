// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../lib/Ownable.sol";
import "../lib/SafeMath.sol";
import "../lib/SafeERC20.sol";

import "./../interfaces/IYakFeeCollectorV1.sol";

/**
 * @title YY Staking
 * @author Yield Yak
 * @notice YakStakingAvalanche is a contract that allows ERC20 deposits and receives rewards from token balances which may be
 * transferred in without an additional function call. The contract is based on StableJoeStaking from Trader Joe.
 * Users deposit X and receive a share of what has been sent based on their participation of the total deposits.
 * It is similar to a MasterChef, but we allow for claiming of different reward tokens.
 * Every time `updateReward(token)` is called, We distribute the balance of that tokens as rewards to users that are
 * currently staking inside this contract, and they can claim it using `withdraw(0)`
 */
contract YakStakingAvalanche is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user
    struct UserInfo {
        uint256 amount;
        mapping(IERC20 => uint256) rewardDebt;
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

    /// @notice Farm deposit token
    IERC20 public depositToken;

    /// @dev Internal balance of depositToken, this gets updated on user deposits / withdrawals
    /// this allows to reward users with depositToken
    uint256 public internalBalance;

    /// @notice Array of tokens that users can claim
    IERC20[] public rewardTokens;
    mapping(IERC20 => bool) public isRewardToken;

    /// @notice Last reward balance of `token`
    mapping(IERC20 => uint256) public lastRewardBalance;

    address public legacyYakFeeCollector;

    address public feeCollector;

    /// @notice The deposit fee, scaled to `DEPOSIT_FEE_PERCENT_PRECISION`
    uint256 public depositFeePercent;
    uint256 public immutable MAX_DEPOSIT_FEE_BIPS;

    /// @dev The precision of `depositFeePercent`
    uint256 internal constant DEPOSIT_FEE_PERCENT_PRECISION = 10000;

    /// @notice Accumulated `token` rewards per share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    mapping(IERC20 => uint256) public accRewardPerShare;
    /// @notice The precision of `accRewardPerShare`
    uint256 public ACC_REWARD_PER_SHARE_PRECISION;

    /// @dev Info of each user that stakes
    mapping(address => UserInfo) private userInfo;

    /// @notice Emitted when a user deposits
    event Deposit(address indexed user, uint256 amount, uint256 fee);

    /// @notice Emitted when feeCollector changes the fee collector
    event FeeCollectorChanged(address newFeeCollector, address oldFeeCollector);

    /// @notice Emitted when owner changes the deposit fee percentage
    event DepositFeeChanged(uint256 newFee, uint256 oldFee);

    /// @notice Emitted when a user withdraws
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims reward
    event ClaimReward(address indexed user, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when a user emergency withdraws
    event EmergencyWithdraw(address indexed user, uint256 amount);

    /// @notice Emitted when owner adds a token to the reward tokens list
    event RewardTokenAdded(address token);

    /// @notice Emitted when owner removes a token from the reward tokens list
    event RewardTokenRemoved(address token);

    constructor(IERC20 _depositToken, IERC20 _rewardToken, address _feeCollector, uint256 _maxDepositFeeBips) {
        require(address(_depositToken) != address(0), "YyStaking::depositToken can't be address(0)");
        require(address(_rewardToken) != address(0), "YyStaking::rewardToken can't be address(0)");
        require(_feeCollector != address(0), "YyStaking::feeCollector can't be address(0)");

        depositToken = _depositToken;
        feeCollector = _feeCollector;

        isRewardToken[_rewardToken] = true;
        rewardTokens.push(_rewardToken);
        ACC_REWARD_PER_SHARE_PRECISION = 1e24;
        MAX_DEPOSIT_FEE_BIPS = _maxDepositFeeBips;
    }

    function setLegacyFeeCollector(address _legacyFeeCollector) external onlyOwner {
        require(IYakFeeCollectorV1(_legacyFeeCollector).hasRole(keccak256("TOKEN_SWEEPER_ROLE"), address(this)));
        legacyYakFeeCollector = _legacyFeeCollector;
    }

    /**
     * @notice Deposit for reward token allocation
     * @param amount The amount of depositToken to deposit
     */
    function deposit(uint256 amount) external {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Deposit on behalf of another account
     * @param account Account to deposit for
     * @param amount The amount of depositToken to deposit
     */
    function depositFor(address account, uint256 amount) external {
        _deposit(account, amount);
    }

    /**
     * @notice Deposit using Permit
     * @param amount The amount of depositToken to deposit
     * @param deadline The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function _deposit(address _account, uint256 _amount) internal {
        UserInfo storage user = userInfo[_account];

        uint256 _fee = _amount.mul(depositFeePercent).div(DEPOSIT_FEE_PERCENT_PRECISION);
        uint256 _amountMinusFee = _amount.sub(_fee);

        uint256 _previousAmount = user.amount;
        uint256 _newAmount = user.amount.add(_amountMinusFee);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            updateReward(_token);

            uint256 _previousRewardDebt = user.rewardDebt[_token];
            user.rewardDebt[_token] = _newAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION);

            if (_previousAmount != 0) {
                uint256 _pending = _previousAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION)
                    .sub(_previousRewardDebt);
                if (_pending != 0) {
                    safeTokenTransfer(_token, _account, _pending);
                    emit ClaimReward(_account, address(_token), _pending);
                }
            }
        }

        internalBalance = internalBalance.add(_amountMinusFee);
        depositToken.safeTransferFrom(msg.sender, feeCollector, _fee);
        depositToken.safeTransferFrom(msg.sender, address(this), _amountMinusFee);
        emit Deposit(_account, _amountMinusFee, _fee);
    }

    /**
     * @notice Get user info
     * @param _user The address of the user
     * @param _rewardToken The address of the reward token
     * @return The amount of depositToken user has deposited
     * @return The reward debt for the chosen token
     */
    function getUserInfo(address _user, IERC20 _rewardToken) external view returns (uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        return (user.amount, user.rewardDebt[_rewardToken]);
    }

    /**
     * @notice Get the number of reward tokens
     * @return The length of the array
     */
    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice Add a reward token
     * @param _rewardToken The address of the reward token
     */
    function addRewardToken(IERC20 _rewardToken) external onlyOwner {
        require(
            !isRewardToken[_rewardToken] && address(_rewardToken) != address(0), "YyStaking::rewardToken can't be added"
        );
        require(rewardTokens.length < 25, "YyStaking::list of rewardTokens too big");
        rewardTokens.push(_rewardToken);
        isRewardToken[_rewardToken] = true;
        updateReward(_rewardToken);
        emit RewardTokenAdded(address(_rewardToken));
    }

    /**
     * @notice Remove a reward token
     * @param _rewardToken The address of the reward token
     */
    function removeRewardToken(IERC20 _rewardToken) external onlyOwner {
        require(isRewardToken[_rewardToken], "YyStaking::rewardToken can't be removed");
        updateReward(_rewardToken);
        isRewardToken[_rewardToken] = false;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            if (rewardTokens[i] == _rewardToken) {
                rewardTokens[i] = rewardTokens[_len - 1];
                rewardTokens.pop();
                accRewardPerShare[_rewardToken] = 0;
                lastRewardBalance[_rewardToken] = 0;
                break;
            }
        }
        emit RewardTokenRemoved(address(_rewardToken));
    }

    /**
     * @notice Set the deposit fee percent
     * @param _depositFeePercent The new deposit fee percent
     */
    function setDepositFeePercent(uint256 _depositFeePercent) external onlyOwner {
        require(_depositFeePercent <= MAX_DEPOSIT_FEE_BIPS, "YyStaking::deposit fee too high");
        emit DepositFeeChanged(_depositFeePercent, depositFeePercent);
        depositFeePercent = _depositFeePercent;
    }

    /**
     * @notice View function to see pending reward token on frontend
     * @param _user The address of the user
     * @param _token The address of the token
     * @return `_user`'s pending reward token
     */
    function pendingReward(address _user, IERC20 _token) external view returns (uint256) {
        if (!isRewardToken[_token]) {
            return 0;
        }

        UserInfo storage user = userInfo[_user];
        uint256 _totalDepositTokens = internalBalance;
        uint256 _accRewardTokenPerShare = accRewardPerShare[_token];

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        if (legacyYakFeeCollector > address(0)) {
            _currRewardBalance += _token.balanceOf(legacyYakFeeCollector);
        }
        uint256 _rewardBalance =
            _token == depositToken ? _currRewardBalance.sub(_totalDepositTokens) : _currRewardBalance;

        if (_rewardBalance != lastRewardBalance[_token] && _totalDepositTokens != 0) {
            uint256 _accruedReward = _rewardBalance.sub(lastRewardBalance[_token]);
            _accRewardTokenPerShare =
                _accRewardTokenPerShare.add(_accruedReward.mul(ACC_REWARD_PER_SHARE_PRECISION).div(_totalDepositTokens));
        }
        return user.amount.mul(_accRewardTokenPerShare).div(ACC_REWARD_PER_SHARE_PRECISION).sub(user.rewardDebt[_token]);
    }

    /**
     * @notice Withdraw and harvest the rewards
     * @param _amount The amount to withdraw
     */
    function withdraw(uint256 _amount) external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 _previousAmount = user.amount;
        require(_amount <= _previousAmount, "YyStaking::withdraw amount exceeds balance");
        uint256 _newAmount = user.amount.sub(_amount);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        if (_previousAmount != 0) {
            for (uint256 i; i < _len; i++) {
                IERC20 _token = rewardTokens[i];
                updateReward(_token);

                uint256 _pending = _previousAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION)
                    .sub(user.rewardDebt[_token]);
                user.rewardDebt[_token] = _newAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION);

                if (_pending != 0) {
                    safeTokenTransfer(_token, msg.sender, _pending);
                    emit ClaimReward(msg.sender, address(_token), _pending);
                }
            }
        }

        internalBalance = internalBalance.sub(_amount);
        depositToken.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY
     */
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];

        uint256 _amount = user.amount;
        user.amount = 0;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            user.rewardDebt[_token] = 0;
        }
        internalBalance = internalBalance.sub(_amount);
        depositToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _amount);
    }

    /**
     * @notice Update reward variables
     * @param _token The address of the reward token
     * @dev Needs to be called before any deposit or withdrawal
     */
    function updateReward(IERC20 _token) public {
        require(isRewardToken[_token], "YyStaking::wrong reward token");

        if (legacyYakFeeCollector > address(0)) {
            try IYakFeeCollectorV1(legacyYakFeeCollector).sweepTokens(address(_token), type(uint256).max) {} catch {}
        }

        uint256 _totalDepositTokens = internalBalance;

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance =
            _token == depositToken ? _currRewardBalance.sub(_totalDepositTokens) : _currRewardBalance;

        // Did YyStaking receive any token
        if (_rewardBalance == lastRewardBalance[_token] || _totalDepositTokens == 0) {
            return;
        }

        uint256 _accruedReward = _rewardBalance.sub(lastRewardBalance[_token]);

        accRewardPerShare[_token] =
            accRewardPerShare[_token].add(_accruedReward.mul(ACC_REWARD_PER_SHARE_PRECISION).div(_totalDepositTokens));
        lastRewardBalance[_token] = _rewardBalance;
    }

    /**
     * @notice Update fee collector
     * @dev Restricted to existing fee collector
     * @param _newFeeCollector The address of the new fee collector
     */
    function updateFeeCollector(address _newFeeCollector) external onlyOwner {
        emit FeeCollectorChanged(_newFeeCollector, feeCollector);
        feeCollector = _newFeeCollector;
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
        uint256 _rewardBalance = _token == depositToken ? _currRewardBalance.sub(internalBalance) : _currRewardBalance;

        if (_amount > _rewardBalance) {
            lastRewardBalance[_token] = lastRewardBalance[_token].sub(_rewardBalance);
            _token.safeTransfer(_to, _rewardBalance);
        } else {
            lastRewardBalance[_token] = lastRewardBalance[_token].sub(_amount);
            _token.safeTransfer(_to, _amount);
        }
    }
}
