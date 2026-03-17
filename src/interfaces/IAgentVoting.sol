// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentVoting {
    struct Poll {
        address creator;
        string title;
        string[] options;
        uint48 deadline;
        bool reputationWeighted;
        bool closed;
        uint256[] voteCounts;
    }

    event PollCreated(uint256 indexed pollId, address indexed creator, string title, uint48 deadline, bool weighted);
    event VoteCast(uint256 indexed pollId, address indexed voter, uint256 optionIndex, uint256 weight);
    event PollClosed(uint256 indexed pollId, uint256 winningOption, uint256 winningVotes);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event VoteFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error TooManyOptions(uint256 count);
    error TooFewOptions(uint256 count);
    error EmptyTitle();
    error DeadlineTooSoon(uint48 deadline);
    error PollNotFound(uint256 pollId);
    error PollNotActive(uint256 pollId);
    error PollNotEnded(uint256 pollId);
    error AlreadyVoted(uint256 pollId, address voter);
    error InvalidOption(uint256 pollId, uint256 optionIndex);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
}
