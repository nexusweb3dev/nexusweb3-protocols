// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentEscrowV2
/// @notice Milestone escrow between a client (payer) and a provider (payee), optional arbiter.
///         Funds are pulled from the client principal; either party may act via operators.
///         Absorbs v1 AgentEscrow, AgentMilestone and AgentMarket order flow.
///
/// Lifecycle:
///   createJob  -> Open
///   provider submitMilestone(i)  (Pending -> Submitted)
///   client approveMilestone(i)   (-> Approved, pays provider minus fee; allowed even if not Submitted)
///   client rejectMilestone(i)    (Submitted -> Pending, provider may resubmit)
///   provider claimApproval(i)    (Submitted and unreviewed for REVIEW_WINDOW -> Approved; client silence = acceptance)
///   all approved                 -> Completed
///   client cancelJob             -> Cancelled (only while no milestone Submitted/Approved), full refund
///   either party dispute         -> Disputed (requires arbiter != 0, only before the deadline)
///   arbiter resolve(providerBps) -> Resolved (remaining funds split)
///   anyone refundExpired         -> Expired (after expiry, unreleased funds to client)
///
/// Expiry = max(deadline, latest Submitted milestone's submittedAt + REVIEW_WINDOW). Disputes are
/// only possible before expiry; refundExpired only after it. A client who ignores a submission
/// therefore cannot run out the clock: the provider can claim it after REVIEW_WINDOW.
interface IAgentEscrowV2 {
    enum JobStatus {
        Open,
        Completed,
        Cancelled,
        Disputed,
        Resolved,
        Expired
    }

    enum MilestoneStatus {
        Pending,
        Submitted,
        Approved
    }

    struct Job {
        address client;
        address provider;
        address arbiter; // address(0) = no dispute path, deadline only
        uint256 total;
        uint256 released; // paid to provider (gross, before fee)
        uint256 refunded; // returned to client
        uint48 deadline;
        uint48 createdAt;
        uint8 milestoneCount;
        uint8 approvedCount;
        JobStatus status;
        bytes32 termsHash; // hash of off-chain terms document
    }

    struct Milestone {
        uint256 amount;
        bytes32 deliverableHash;
        uint48 submittedAt;
        MilestoneStatus status;
    }

    struct CreateParams {
        address client;
        address provider;
        address arbiter;
        uint256[] milestoneAmounts; // 1..20, each > 0
        uint48 deadline; // now + 1h .. now + 365d
        bytes32 termsHash;
    }

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address arbiter,
        uint256 total,
        uint48 deadline
    );
    event MilestoneSubmitted(uint256 indexed jobId, uint8 indexed index, bytes32 deliverableHash);
    event MilestoneApproved(uint256 indexed jobId, uint8 indexed index, uint256 payout, uint256 fee);
    event MilestoneClaimed(uint256 indexed jobId, uint8 indexed index);
    event MilestoneRejected(uint256 indexed jobId, uint8 indexed index, bytes32 reasonHash);
    event JobCompleted(uint256 indexed jobId);
    event JobCancelled(uint256 indexed jobId, uint256 refund);
    event JobDisputed(uint256 indexed jobId, address indexed by, bytes32 reasonHash);
    event JobResolved(uint256 indexed jobId, uint16 providerBps, uint256 toProvider, uint256 toClient, uint256 fee);
    event JobExpired(uint256 indexed jobId, uint256 refund);
    event ClaimableAdded(address indexed account, uint256 amount);
    event ClaimableWithdrawn(address indexed account, uint256 amount);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event ModulesUpdated(address reputation, address auditLog, address killSwitch, address feeRouter);

    error ZeroAddress();
    error InvalidParty();
    error InvalidMilestones();
    error InvalidDeadline();
    error JobNotFound(uint256 jobId);
    error MilestoneNotFound(uint256 jobId, uint8 index);
    error WrongJobStatus(uint256 jobId, JobStatus current);
    error WrongMilestoneStatus(uint256 jobId, uint8 index, MilestoneStatus current);
    error NotClient(uint256 jobId);
    error NotProvider(uint256 jobId);
    error NotParty(uint256 jobId);
    error NotArbiter(uint256 jobId);
    error NoArbiter(uint256 jobId);
    error CannotCancel(uint256 jobId);
    error DeadlineNotReached(uint256 jobId);
    error DeadlinePassed(uint256 jobId);
    error ReviewWindowOpen(uint256 jobId, uint8 index, uint48 claimableAt);
    error InvalidBps(uint16 bps);
    error FeeTooHigh(uint256 bps);
    error NothingToClaim();
    error NotSelf();
    error InsufficientGas(uint256 required);
    error ProviderInactive(address provider);

    // ─── Client (principal or operator) ─────────────────────────────────
    function createJob(CreateParams calldata p) external returns (uint256 jobId);
    /// @notice Same as createJob but first calls IERC20Permit(paymentToken).permit(client, this, total, ...).
    function createJobWithPermit(
        CreateParams calldata p,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256 jobId);
    function approveMilestone(uint256 jobId, uint8 index) external;
    function rejectMilestone(uint256 jobId, uint8 index, bytes32 reasonHash) external;
    function cancelJob(uint256 jobId) external;

    // ─── Provider (principal or operator) ───────────────────────────────
    function submitMilestone(uint256 jobId, uint8 index, bytes32 deliverableHash) external;
    /// @notice Approve a milestone the client has left Submitted for longer than REVIEW_WINDOW.
    function claimApproval(uint256 jobId, uint8 index) external;

    // ─── Either party ───────────────────────────────────────────────────
    function dispute(uint256 jobId, bytes32 reasonHash) external;

    // ─── Arbiter ────────────────────────────────────────────────────────
    function resolve(uint256 jobId, uint16 providerBps) external;

    // ─── Anyone ─────────────────────────────────────────────────────────
    function refundExpired(uint256 jobId) external;
    function withdrawClaimable() external;

    // ─── Views ──────────────────────────────────────────────────────────
    function getJob(uint256 jobId) external view returns (Job memory);
    function getMilestones(uint256 jobId) external view returns (Milestone[] memory);
    function getJobsOf(address account, uint256 offset, uint256 limit) external view returns (uint256[] memory);
    function jobCountOf(address account) external view returns (uint256);
    function jobCount() external view returns (uint256);
    /// @notice Timestamp after which refundExpired works and dispute no longer does.
    function expiryOf(uint256 jobId) external view returns (uint48);
    function claimable(address account) external view returns (uint256);
    function feeBps() external view returns (uint256);
    function paymentToken() external view returns (address);
    function reputation() external view returns (address);
    function auditLog() external view returns (address);
    function killSwitch() external view returns (address);
    function feeRouter() external view returns (address);

    // ─── Owner (governance) ─────────────────────────────────────────────
    function setFeeBps(uint256 newBps) external;
    function setModules(address reputation, address auditLog, address killSwitch, address feeRouter) external;
}
