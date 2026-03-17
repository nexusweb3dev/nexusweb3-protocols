// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentCollective {
    struct Collective {
        string name;
        uint8 collectiveType;
        uint256 entryFee;
        uint256 profitShareBps;
        uint256 treasury;
        uint256 memberCount;
        uint48 createdAt;
        bool active;
    }

    struct Proposal {
        string title;
        uint48 deadline;
        uint256 forVotes;
        uint256 againstVotes;
    }

    event CollectiveCreated(uint256 indexed id, string name, uint8 collectiveType, uint256 entryFee, uint256 profitShareBps);
    event MemberJoined(uint256 indexed id, address indexed member);
    event MemberLeft(uint256 indexed id, address indexed member, uint256 payout);
    event RevenueDeposited(uint256 indexed id, address indexed depositor, uint256 amount);
    event ProfitDistributed(uint256 indexed id, uint256 totalDistributed, uint256 perMember);
    event ProposalCreated(uint256 indexed collectiveId, uint256 indexed proposalId, string title, uint48 deadline);
    event VoteCast(uint256 indexed collectiveId, uint256 indexed proposalId, address indexed voter, bool support);
    event AumFeeCharged(uint256 indexed id, uint256 fee);
    event EmergencyWithdrawal(uint256 indexed id, address indexed member, uint256 payout);
    event FeesCollected(uint256 ethAmount, uint256 usdcAmount, address indexed treasury);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error InvalidCollective(uint256 id);
    error InactiveCollective(uint256 id);
    error NotMember(uint256 id, address caller);
    error AlreadyMember(uint256 id, address caller);
    error LockPeriodActive(uint256 id, address member);
    error DistributionCooldown(uint256 id);
    error EmptyTreasury(uint256 id);
    error NoMembers(uint256 id);
    error InvalidProfitShare(uint256 bps);
    error InvalidCollectiveType(uint8 t);
    error SoulboundToken();
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error ZeroAmount();
    error EmptyName();
    error NoFeesToCollect();
    error ProposalNotFound(uint256 collectiveId, uint256 proposalId);
    error ProposalExpired(uint256 collectiveId, uint256 proposalId);
    error AlreadyVoted(uint256 collectiveId, uint256 proposalId, address voter);
    error ProposalDeadlineTooSoon();
    error NoPendingDistribution(uint256 id, address member);

    event DistributionClaimed(uint256 indexed id, address indexed member, uint256 amount);
}
