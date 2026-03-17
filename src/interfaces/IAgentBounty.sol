// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentBounty {
    enum BountyStatus { Open, Completed, Cancelled, Expired }

    struct Bounty {
        address poster;
        string title;
        string requirements;
        uint256 reward;
        uint48 deadline;
        bytes32 validationHash;
        address winner;
        BountyStatus status;
        uint256 submissionCount;
    }

    struct Submission {
        address submitter;
        bytes32 solutionHash;
        uint48 submittedAt;
    }

    event BountyPosted(uint256 indexed bountyId, address indexed poster, uint256 reward, uint48 deadline);
    event SolutionSubmitted(uint256 indexed bountyId, address indexed submitter, bytes32 solutionHash);
    event BountyCompleted(uint256 indexed bountyId, address indexed winner, uint256 payout);
    event BountyCancelled(uint256 indexed bountyId, uint256 refund);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error BountyNotFound(uint256 bountyId);
    error BountyNotOpen(uint256 bountyId);
    error BountyExpired(uint256 bountyId);
    error BountyHasSubmissions(uint256 bountyId);
    error NotPoster(uint256 bountyId);
    error AlreadySubmitted(uint256 bountyId, address submitter);
    error InvalidSolution(uint256 bountyId);
    error InvalidValidationHash();
    error InvalidReward();
    error InvalidDeadline();
    error EmptyTitle();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NoFeesToCollect();
    error NothingToClaim();
}
