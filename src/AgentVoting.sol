// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentVoting} from "./interfaces/IAgentVoting.sol";

/// @notice Lightweight on-chain polling for AI agent collectives. One-agent-one-vote or reputation-weighted.
interface IReputationReader {
    function getScoreFree(address agent) external view returns (uint256);
}

contract AgentVoting is Ownable, ReentrancyGuard, Pausable, IAgentVoting {
    uint256 public constant MAX_OPTIONS = 10;
    uint256 public constant MIN_OPTIONS = 2;
    uint256 public constant MIN_DEADLINE_OFFSET = 1 hours;

    IReputationReader public immutable reputation;

    uint256 public creationFee;
    uint256 public voteFee;
    address public treasury;
    uint256 public pollCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Poll) private _polls;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;
    mapping(uint256 => mapping(address => uint256)) private _voterChoice;

    constructor(
        address reputation_,
        address treasury_,
        address owner_,
        uint256 creationFee_,
        uint256 voteFee_
    ) Ownable(owner_) {
        if (reputation_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        reputation = IReputationReader(reputation_);
        treasury = treasury_;
        creationFee = creationFee_;
        voteFee = voteFee_;
    }

    // ─── Create Poll ────────────────────────────────────────────────────

    /// @notice Create a poll with up to 10 options.
    function createPoll(
        string calldata title,
        string[] calldata options,
        uint48 deadline,
        bool reputationWeighted
    ) external payable nonReentrant whenNotPaused returns (uint256 pollId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (options.length < MIN_OPTIONS) revert TooFewOptions(options.length);
        if (options.length > MAX_OPTIONS) revert TooManyOptions(options.length);
        if (deadline < uint48(block.timestamp) + uint48(MIN_DEADLINE_OFFSET)) revert DeadlineTooSoon(deadline);
        if (msg.value < creationFee) revert InsufficientFee(creationFee, msg.value);

        pollId = pollCount++;
        Poll storage p = _polls[pollId];
        p.creator = msg.sender;
        p.title = title;
        p.deadline = deadline;
        p.reputationWeighted = reputationWeighted;
        p.closed = false;
        p.voteCounts = new uint256[](options.length);
        for (uint256 i; i < options.length; i++) {
            p.options.push(options[i]);
        }

        accumulatedFees += msg.value;

        emit PollCreated(pollId, msg.sender, title, deadline, reputationWeighted);
    }

    // ─── Vote ───────────────────────────────────────────────────────────

    /// @notice Cast a vote on a poll.
    function castVote(uint256 pollId, uint256 optionIndex) external payable nonReentrant whenNotPaused {
        Poll storage p = _getPoll(pollId);
        if (p.closed) revert PollNotActive(pollId);
        if (uint48(block.timestamp) >= p.deadline) revert PollNotActive(pollId);
        if (_hasVoted[pollId][msg.sender]) revert AlreadyVoted(pollId, msg.sender);
        if (optionIndex >= p.options.length) revert InvalidOption(pollId, optionIndex);
        if (msg.value < voteFee) revert InsufficientFee(voteFee, msg.value);

        _hasVoted[pollId][msg.sender] = true;
        _voterChoice[pollId][msg.sender] = optionIndex;

        uint256 weight = 1;
        if (p.reputationWeighted) {
            weight = reputation.getScoreFree(msg.sender);
            if (weight == 0) weight = 1;
        }

        p.voteCounts[optionIndex] += weight;
        accumulatedFees += msg.value;

        emit VoteCast(pollId, msg.sender, optionIndex, weight);
    }

    // ─── Close ──────────────────────────────────────────────────────────

    /// @notice Close a poll after deadline. Records permanent result.
    function closePoll(uint256 pollId) external {
        Poll storage p = _getPoll(pollId);
        if (p.closed) revert PollNotActive(pollId);
        if (uint48(block.timestamp) < p.deadline) revert PollNotEnded(pollId);

        p.closed = true;

        (uint256 winIdx, uint256 winVotes) = _findWinner(p);
        emit PollClosed(pollId, winIdx, winVotes);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect accumulated fees to treasury.
    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Fee transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setCreationFee(uint256 newFee) external onlyOwner {
        uint256 old = creationFee;
        creationFee = newFee;
        emit CreationFeeUpdated(old, newFee);
    }

    function setVoteFee(uint256 newFee) external onlyOwner {
        uint256 old = voteFee;
        voteFee = newFee;
        emit VoteFeeUpdated(old, newFee);
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

    function getPoll(uint256 pollId) external view returns (Poll memory) {
        if (pollId >= pollCount) revert PollNotFound(pollId);
        return _polls[pollId];
    }

    function getResult(uint256 pollId) external view returns (uint256 winningOption, uint256 winningVotes) {
        Poll storage p = _getPoll(pollId);
        return _findWinner(p);
    }

    function getVote(uint256 pollId, address voter) external view returns (uint256) {
        return _voterChoice[pollId][voter];
    }

    function hasVoted(uint256 pollId, address voter) external view returns (bool) {
        return _hasVoted[pollId][voter];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getPoll(uint256 pollId) internal view returns (Poll storage) {
        if (pollId >= pollCount) revert PollNotFound(pollId);
        return _polls[pollId];
    }

    function _findWinner(Poll storage p) internal view returns (uint256 winIdx, uint256 winVotes) {
        for (uint256 i; i < p.voteCounts.length; i++) {
            if (p.voteCounts[i] > winVotes) {
                winVotes = p.voteCounts[i];
                winIdx = i;
            }
        }
    }
}
