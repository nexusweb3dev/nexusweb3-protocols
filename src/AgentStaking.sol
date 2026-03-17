// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentStaking} from "./interfaces/IAgentStaking.sol";

/// @notice Stake NEXUS tokens to earn protocol revenue share. Lock longer = higher boost.
contract AgentStaking is Ownable, ReentrancyGuard, Pausable, IAgentStaking {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant REVENUE_SHARE_BPS = 5000; // 50% to stakers

    IERC20 public immutable nexusToken;

    address public treasury;
    uint256 public stakeCount;
    uint256 public totalWeightedStake;
    uint256 public accRewardPerShare;
    uint256 public pendingRevenue;

    mapping(uint256 => StakeInfo) private _stakes;
    mapping(address => uint256[]) private _userStakes;
    mapping(address => bool) private _authorizedProtocols;
    mapping(uint256 => uint256) private _boostForLockDays;
    mapping(address => uint256) public claimableRewards; // F1 fix: fallback for failed ETH sends

    constructor(IERC20 nexusToken_, address treasury_, address owner_) Ownable(owner_) {
        if (address(nexusToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        nexusToken = nexusToken_;
        treasury = treasury_;

        _boostForLockDays[7] = 10000;     // 1x  (7-day minimum prevents flash loan attacks)
        _boostForLockDays[30] = 12500;   // 1.25x
        _boostForLockDays[90] = 15000;   // 1.5x
        _boostForLockDays[180] = 20000;  // 2x
        _boostForLockDays[365] = 30000;  // 3x
    }

    // ─── Stake ──────────────────────────────────────────────────────────

    /// @notice Stake NEXUS tokens with optional lock period for boosted yield.
    function stake(uint256 amount, uint256 lockDays) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (amount == 0) revert ZeroAmount();
        uint256 boost = _boostForLockDays[lockDays];
        if (boost == 0) revert InvalidLockPeriod(lockDays);

        // weighted = amount * boost / 10000
        uint256 weighted = amount * boost / 10000;
        // all stakes have a real lock — minimum 7 days prevents flash loan attacks
        uint48 lockUntil = uint48(block.timestamp + lockDays * 1 days);

        stakeId = stakeCount++;
        _stakes[stakeId] = StakeInfo({
            owner: msg.sender,
            amount: amount,
            weightedAmount: weighted,
            lockUntil: lockUntil,
            rewardDebt: weighted * accRewardPerShare / PRECISION,
            active: true
        });
        _userStakes[msg.sender].push(stakeId);
        totalWeightedStake += weighted;

        nexusToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(stakeId, msg.sender, amount, lockDays, boost);
    }

    // ─── Unstake ────────────────────────────────────────────────────────

    /// @notice Withdraw staked tokens + claim pending rewards.
    function unstake(uint256 stakeId) external nonReentrant {
        StakeInfo storage s = _getStake(stakeId);
        if (!s.active) revert StakeNotActive(stakeId);
        if (s.owner != msg.sender) revert NotStakeOwner(stakeId);
        if (s.lockUntil > 0 && uint48(block.timestamp) < s.lockUntil) {
            revert LockNotExpired(stakeId, s.lockUntil);
        }

        uint256 pending = _pendingReward(s);
        s.active = false;
        s.rewardDebt = 0;
        totalWeightedStake -= s.weightedAmount;

        // CRITICAL: return NEXUS first — this must NEVER be blocked
        nexusToken.safeTransfer(msg.sender, s.amount);

        // ETH rewards: try to send, store in claimable if it fails
        if (pending > 0) {
            (bool ok,) = msg.sender.call{value: pending}("");
            if (!ok) {
                claimableRewards[msg.sender] += pending;
            }
        }

        emit Unstaked(stakeId, msg.sender, s.amount, pending);
    }

    // ─── Claim Rewards ──────────────────────────────────────────────────

    /// @notice Claim pending ETH rewards without unstaking.
    function claimRewards(uint256 stakeId) external nonReentrant {
        StakeInfo storage s = _getStake(stakeId);
        if (!s.active) revert StakeNotActive(stakeId);
        if (s.owner != msg.sender) revert NotStakeOwner(stakeId);

        uint256 pending = _pendingReward(s);
        if (pending == 0) revert NothingToClaim(stakeId);

        s.rewardDebt = s.weightedAmount * accRewardPerShare / PRECISION;

        (bool ok,) = msg.sender.call{value: pending}("");
        if (!ok) {
            claimableRewards[msg.sender] += pending;
        }

        emit RewardsClaimed(stakeId, msg.sender, pending);
    }

    /// @notice Withdraw ETH rewards that failed to send directly.
    function withdrawClaimable() external nonReentrant {
        uint256 amount = claimableRewards[msg.sender];
        if (amount == 0) revert NothingToClaim(0);
        claimableRewards[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    // ─── Revenue Distribution ───────────────────────────────────────────

    /// @notice Distribute accumulated revenue to stakers (50%) and treasury (50%).
    function distributeRevenue() external nonReentrant {
        uint256 revenue = pendingRevenue;
        if (revenue == 0) revert NoRevenue();
        if (totalWeightedStake == 0) revert NoRevenue();

        pendingRevenue = 0;
        uint256 stakerShare = revenue * REVENUE_SHARE_BPS / 10000;
        uint256 treasuryShare = revenue - stakerShare;

        // update accumulated reward per share
        accRewardPerShare += stakerShare * PRECISION / totalWeightedStake;

        // treasury gets its share — failure must not block staker rewards
        if (treasuryShare > 0) {
            (bool ok,) = treasury.call{value: treasuryShare}("");
            if (!ok) {
                claimableRewards[treasury] += treasuryShare;
            }
        }

        emit RevenueDistributed(revenue, totalWeightedStake);
    }

    event RevenueReceived(address indexed from, uint256 amount);

    /// @notice Receive ETH revenue from authorized protocols.
    function addRevenue() external payable {
        if (!_authorizedProtocols[msg.sender] && msg.sender != owner()) {
            revert NotAuthorizedProtocol(msg.sender);
        }
        pendingRevenue += msg.value;
        emit RevenueReceived(msg.sender, msg.value);
    }

    // Accept ETH from any source — becomes staker revenue
    receive() external payable {
        pendingRevenue += msg.value;
        emit RevenueReceived(msg.sender, msg.value);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);
        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocols[protocol]) revert NotAuthorized(protocol);
        _authorizedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getStake(uint256 stakeId) external view returns (StakeInfo memory) {
        if (stakeId >= stakeCount) revert StakeNotFound(stakeId);
        return _stakes[stakeId];
    }

    function getPendingRewards(uint256 stakeId) external view returns (uint256) {
        if (stakeId >= stakeCount) return 0;
        StakeInfo storage s = _stakes[stakeId];
        if (!s.active) return 0;
        return _pendingReward(s);
    }

    function getUserStakes(address user) external view returns (uint256[] memory) {
        return _userStakes[user];
    }

    function getBoost(uint256 lockDays) external view returns (uint256) {
        return _boostForLockDays[lockDays];
    }

    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getStake(uint256 stakeId) internal view returns (StakeInfo storage) {
        if (stakeId >= stakeCount) revert StakeNotFound(stakeId);
        return _stakes[stakeId];
    }

    function _pendingReward(StakeInfo storage s) internal view returns (uint256) {
        uint256 accReward = s.weightedAmount * accRewardPerShare / PRECISION;
        return accReward > s.rewardDebt ? accReward - s.rewardDebt : 0;
    }
}
