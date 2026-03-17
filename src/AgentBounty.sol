// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentBounty} from "./interfaces/IAgentBounty.sol";

/// @notice On-chain bounty system. Post rewards, agents solve, auto-validate, instant payout.
contract AgentBounty is Ownable, ReentrancyGuard, Pausable, IAgentBounty {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_REWARD = 1_000_000; // $1 USDC
    uint256 public constant MIN_DEADLINE_OFFSET = 1 hours;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public bountyCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => Submission[]) private _submissions;
    mapping(uint256 => mapping(address => bool)) private _hasSubmitted;
    mapping(address => uint256) private _claimable;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
    }

    // ─── Post Bounty ────────────────────────────────────────────────────

    /// @notice Post a bounty with USDC reward. Platform fee taken upfront.
    function postBounty(
        string calldata title,
        string calldata requirements,
        uint256 reward,
        uint48 deadline,
        bytes32 validationHash
    ) external nonReentrant whenNotPaused returns (uint256 bountyId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (reward < MIN_REWARD) revert InvalidReward();
        if (deadline < uint48(block.timestamp) + uint48(MIN_DEADLINE_OFFSET)) revert InvalidDeadline();
        if (validationHash == bytes32(0)) revert InvalidValidationHash();

        uint256 fee = reward.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 total = reward + fee;

        bountyId = bountyCount++;
        _bounties[bountyId] = Bounty({
            poster: msg.sender,
            title: title,
            requirements: requirements,
            reward: reward,
            deadline: deadline,
            validationHash: validationHash,
            winner: address(0),
            status: BountyStatus.Open,
            submissionCount: 0
        });

        // pull reward + fee from poster
        paymentToken.safeTransferFrom(msg.sender, address(this), total);
        accumulatedFees += fee;

        emit BountyPosted(bountyId, msg.sender, reward, deadline);
    }

    // ─── Submit Solution ────────────────────────────────────────────────

    /// @notice Submit a solution. If hash matches — auto-payout.
    function submitSolution(
        uint256 bountyId,
        bytes32 solutionHash
    ) external nonReentrant whenNotPaused {
        Bounty storage b = _getBounty(bountyId);
        if (b.status != BountyStatus.Open) revert BountyNotOpen(bountyId);
        if (uint48(block.timestamp) > b.deadline) revert BountyExpired(bountyId);
        if (_hasSubmitted[bountyId][msg.sender]) revert AlreadySubmitted(bountyId, msg.sender);

        _hasSubmitted[bountyId][msg.sender] = true;
        b.submissionCount++;
        _submissions[bountyId].push(Submission({
            submitter: msg.sender,
            solutionHash: solutionHash,
            submittedAt: uint48(block.timestamp)
        }));

        emit SolutionSubmitted(bountyId, msg.sender, solutionHash);

        // auto-validate: if solution hash matches validation hash — instant win
        if (solutionHash == b.validationHash) {
            _completeBounty(bountyId, b, msg.sender);
        }
    }

    // ─── Manual Approve ─────────────────────────────────────────────────

    /// @notice Poster manually approves a winner for complex bounties.
    function manualApprove(uint256 bountyId, address winner) external nonReentrant {
        Bounty storage b = _getBounty(bountyId);
        if (b.status != BountyStatus.Open) revert BountyNotOpen(bountyId);
        if (b.poster != msg.sender) revert NotPoster(bountyId);
        if (!_hasSubmitted[bountyId][winner]) revert InvalidSolution(bountyId);

        _completeBounty(bountyId, b, winner);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    /// @notice Cancel bounty. Only if no submissions and still open.
    function cancelBounty(uint256 bountyId) external nonReentrant {
        Bounty storage b = _getBounty(bountyId);
        if (b.poster != msg.sender) revert NotPoster(bountyId);
        if (b.status != BountyStatus.Open) revert BountyNotOpen(bountyId);
        if (b.submissionCount > 0) revert BountyHasSubmissions(bountyId);

        b.status = BountyStatus.Cancelled;

        // refund reward (fee already taken)
        paymentToken.safeTransfer(msg.sender, b.reward);
        emit BountyCancelled(bountyId, b.reward);
    }

    // ─── Expire ─────────────────────────────────────────────────────────

    /// @notice Anyone can mark an expired bounty and return reward to poster.
    function expireBounty(uint256 bountyId) external nonReentrant {
        Bounty storage b = _getBounty(bountyId);
        if (b.status != BountyStatus.Open) revert BountyNotOpen(bountyId);
        if (uint48(block.timestamp) <= b.deadline) revert InvalidDeadline();

        b.status = BountyStatus.Expired;

        // return reward to poster
        try this._safeRefund(b.poster, b.reward) {} catch {
            _claimable[b.poster] += b.reward;
        }
    }

    function _safeRefund(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal only");
        paymentToken.safeTransfer(to, amount);
    }

    // ─── Claim ──────────────────────────────────────────────────────────

    /// @notice Claim USDC from failed payouts.
    function claimRefund() external nonReentrant {
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);
    }

    function getClaimable(address addr) external view returns (uint256) {
        return _claimable[addr];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        paymentToken.safeTransfer(treasury, amount);
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
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

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        if (bountyId >= bountyCount) revert BountyNotFound(bountyId);
        return _bounties[bountyId];
    }

    function getSubmissions(uint256 bountyId) external view returns (Submission[] memory) {
        return _submissions[bountyId];
    }

    function hasSubmitted(uint256 bountyId, address agent) external view returns (bool) {
        return _hasSubmitted[bountyId][agent];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getBounty(uint256 bountyId) internal view returns (Bounty storage) {
        if (bountyId >= bountyCount) revert BountyNotFound(bountyId);
        return _bounties[bountyId];
    }

    function _completeBounty(uint256 bountyId, Bounty storage b, address winner) internal {
        b.status = BountyStatus.Completed;
        b.winner = winner;

        try this._safeRefund(winner, b.reward) {} catch {
            _claimable[winner] += b.reward;
        }

        emit BountyCompleted(bountyId, winner, b.reward);
    }
}
