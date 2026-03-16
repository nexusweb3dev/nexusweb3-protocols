// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentGovernance} from "./interfaces/IAgentGovernance.sol";

/// @notice DAO governance for NexusWeb3. NEXUS holders create/vote proposals with timelock execution.
contract AgentGovernance is Ownable, ReentrancyGuard, Pausable, IAgentGovernance {
    uint256 public constant PROPOSAL_THRESHOLD = 100e18; // 100 NEXUS to propose
    uint256 public constant QUORUM_BPS = 1000; // 10% of snapshot supply
    uint256 public constant TIMELOCK = 2 days;
    uint256 public constant MIN_VOTING_DAYS = 1;
    uint256 public constant MAX_VOTING_DAYS = 14;

    IERC20 public immutable nexusToken;
    uint256 public proposalCount;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    constructor(IERC20 nexusToken_, address owner_) Ownable(owner_) {
        if (address(nexusToken_) == address(0)) revert ZeroAddress();
        nexusToken = nexusToken_;
    }

    /// @notice Create a governance proposal. Requires PROPOSAL_THRESHOLD tokens.
    function createProposal(
        string calldata title,
        bytes calldata callData,
        address target,
        uint256 votingDays
    ) external whenNotPaused returns (uint256 id) {
        if (target == address(0)) revert InvalidTarget();
        if (votingDays < MIN_VOTING_DAYS || votingDays > MAX_VOTING_DAYS) revert InvalidVotingPeriod();
        uint256 balance = nexusToken.balanceOf(msg.sender);
        if (balance < PROPOSAL_THRESHOLD) revert InsufficientTokens(PROPOSAL_THRESHOLD, balance);

        id = proposalCount++;
        uint48 now_ = uint48(block.timestamp);
        uint48 voteEnd = now_ + uint48(votingDays * 1 days);

        _proposals[id] = Proposal({
            proposer: msg.sender,
            title: title,
            callData: callData,
            target: target,
            voteStart: now_,
            voteEnd: voteEnd,
            executableAfter: voteEnd + uint48(TIMELOCK),
            forVotes: 0,
            againstVotes: 0,
            snapshotSupply: nexusToken.totalSupply(),
            state: ProposalState.Active
        });

        emit ProposalCreated(id, msg.sender, title, voteEnd);
    }

    /// @notice Vote on a proposal. Weight = current token balance.
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.Active) revert ProposalNotActive(proposalId);
        if (uint48(block.timestamp) > p.voteEnd) revert ProposalNotActive(proposalId);
        if (_hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = nexusToken.balanceOf(msg.sender);
        if (weight == 0) revert InsufficientTokens(1, 0);

        _hasVoted[proposalId][msg.sender] = true;

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @notice Execute a passed proposal after timelock.
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.Active) revert ProposalNotPassed(proposalId);
        if (uint48(block.timestamp) <= p.voteEnd) revert ProposalNotPassed(proposalId);

        uint256 quorum = p.snapshotSupply * QUORUM_BPS / 10_000;
        if (p.forVotes + p.againstVotes < quorum) revert QuorumNotReached(proposalId);
        if (p.forVotes <= p.againstVotes) {
            p.state = ProposalState.Failed;
            revert ProposalNotPassed(proposalId);
        }
        if (uint48(block.timestamp) < p.executableAfter) {
            revert TimelockNotExpired(proposalId, p.executableAfter);
        }

        p.state = ProposalState.Executed;

        (bool ok,) = p.target.call(p.callData);
        require(ok, "Proposal execution failed");

        emit ProposalExecuted(proposalId);
    }

    /// @notice Owner can cancel malicious proposals.
    function cancelProposal(uint256 proposalId) external onlyOwner {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.Active) revert ProposalNotActive(proposalId);
        p.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
