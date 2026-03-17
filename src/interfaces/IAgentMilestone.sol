// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentMilestone {
    enum MilestoneStatus { Pending, Submitted, Approved, Disputed }

    struct MilestoneContract {
        address client;
        address agent;
        uint256 totalAmount;
        uint256 released;
        uint48 deadline;
        bool active;
        uint256 milestoneCount;
        uint256 nextMilestone;
    }

    struct Milestone {
        bytes32 deliverableHash;
        uint256 amount;
        MilestoneStatus status;
    }

    event ContractCreated(uint256 indexed contractId, address indexed client, address indexed agent, uint256 totalAmount);
    event MilestoneSubmitted(uint256 indexed contractId, uint256 milestoneIndex, bytes32 deliverableHash);
    event MilestoneApproved(uint256 indexed contractId, uint256 milestoneIndex, uint256 payout);
    event MilestoneDisputed(uint256 indexed contractId, uint256 milestoneIndex);
    event DisputeResolved(uint256 indexed contractId, uint256 milestoneIndex, bool approved);
    event ContractCancelled(uint256 indexed contractId, uint256 refund);
    event ContractExpired(uint256 indexed contractId, uint256 refund);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error ContractNotFound(uint256 contractId);
    error ContractNotActive(uint256 contractId);
    error NotClient(uint256 contractId);
    error NotAgent(uint256 contractId);
    error MilestoneNotPending(uint256 contractId, uint256 index);
    error MilestoneNotSubmitted(uint256 contractId, uint256 index);
    error MilestoneOutOfOrder(uint256 contractId, uint256 index, uint256 expected);
    error InvalidDeliverableHash(uint256 contractId, uint256 index);
    error MilestonesAlreadyDelivered(uint256 contractId);
    error ContractExpiredError(uint256 contractId);
    error AmountMismatch(uint256 sum, uint256 total);
    error EmptyMilestones();
    error TooManyMilestones(uint256 count);
    error InvalidDeadline();
    error InvalidAmount();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NoFeesToCollect();
    error NothingToClaim();
}
