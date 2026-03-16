// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentGovernance {
    enum ProposalState { Active, Passed, Failed, Executed, Cancelled }

    struct Proposal {
        address proposer;
        string title;
        bytes callData;
        address target;
        uint48 voteStart;
        uint48 voteEnd;
        uint48 executableAfter;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 snapshotSupply;
        ProposalState state;
    }

    event ProposalCreated(uint256 indexed id, address indexed proposer, string title, uint48 voteEnd);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    error InsufficientTokens(uint256 required, uint256 actual);
    error ProposalNotActive(uint256 id);
    error AlreadyVoted(uint256 id, address voter);
    error ProposalNotPassed(uint256 id);
    error TimelockNotExpired(uint256 id, uint48 executableAfter);
    error InvalidVotingPeriod();
    error InvalidTarget();
    error QuorumNotReached(uint256 id);
    error ZeroAddress();

    function createProposal(string calldata title, bytes calldata callData, address target, uint256 votingDays) external returns (uint256);
    function vote(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function cancelProposal(uint256 proposalId) external;
    function getProposal(uint256 proposalId) external view returns (Proposal memory);
    function proposalCount() external view returns (uint256);
}
