// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";
import {IAgentAccess} from "./interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "./interfaces/IAgentEscrowV2.sol";

/// @title AgentEscrowV2
/// @notice Milestone escrow for agent-to-agent work. Client funds the job (USDC pulled from the
///         client principal), provider submits deliverable hashes, client approves per milestone.
///         Optional party-chosen arbiter resolves disputes. No NexusWeb3 owner action is ever
///         required for a job to complete, refund, or resolve.
contract AgentEscrowV2 is EscrowBase {
    using SafeERC20 for IERC20;

    constructor(IAgentAccess access_, IERC20 token_, address owner_) EscrowBase(access_, token_, owner_) {}

    // ─── Client ─────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function createJob(CreateParams calldata p) external nonReentrant whenNotPaused returns (uint256 jobId) {
        return _create(p);
    }

    /// @inheritdoc IAgentEscrowV2
    function createJobWithPermit(
        CreateParams calldata p,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 jobId)
    {
        uint256 total = _sum(p.milestoneAmounts);
        // Best effort: if the permit was already consumed (front-run), the existing allowance is used.
        try IERC20Permit(address(_token)).permit(p.client, address(this), total, permitDeadline, v, r, s) {} catch {}
        return _create(p);
    }

    /// @inheritdoc IAgentEscrowV2
    function approveMilestone(uint256 jobId, uint8 index) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status == MilestoneStatus.Approved) revert WrongMilestoneStatus(jobId, index, m.status);
        _approve(jobId, job, index, m);
    }

    /// @inheritdoc IAgentEscrowV2
    function claimApproval(uint256 jobId, uint8 index) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.provider, msg.sender)) revert NotProvider(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Submitted) revert WrongMilestoneStatus(jobId, index, m.status);
        uint48 claimableAt = m.submittedAt + uint48(REVIEW_WINDOW);
        if (block.timestamp <= claimableAt) revert ReviewWindowOpen(jobId, index, claimableAt);
        emit MilestoneClaimed(jobId, index);
        _approve(jobId, job, index, m);
    }

    /// @inheritdoc IAgentEscrowV2
    function rejectMilestone(uint256 jobId, uint8 index, bytes32 reasonHash) external {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Submitted) revert WrongMilestoneStatus(jobId, index, m.status);

        m.status = MilestoneStatus.Pending;
        m.submittedAt = 0;
        _logBoth(job, ACT_REJECTED, jobId, index, m.amount);
        emit MilestoneRejected(jobId, index, reasonHash);
    }

    /// @inheritdoc IAgentEscrowV2
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        if (job.approvedCount != 0 || _anySubmitted(jobId, job)) revert CannotCancel(jobId);

        job.status = JobStatus.Cancelled;
        job.refunded = job.total;
        _payOut(job.client, job.total);
        _logBoth(job, ACT_CANCELLED, jobId, 0, job.total);
        emit JobCancelled(jobId, job.total);
    }

    // ─── Provider ───────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function submitMilestone(uint256 jobId, uint8 index, bytes32 deliverableHash) external {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.provider, msg.sender)) revert NotProvider(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Pending) revert WrongMilestoneStatus(jobId, index, m.status);

        m.status = MilestoneStatus.Submitted;
        m.deliverableHash = deliverableHash;
        m.submittedAt = uint48(block.timestamp);
        _log(job.provider, ACT_SUBMITTED, jobId, index, m.amount);
        emit MilestoneSubmitted(jobId, index, deliverableHash);
    }

    // ─── Either party ───────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function dispute(uint256 jobId, bytes32 reasonHash) external {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (job.arbiter == address(0)) revert NoArbiter(jobId);
        if (block.timestamp > _expiry(jobId, job)) revert DeadlinePassed(jobId);
        bool isClient = access.isOperatorFor(job.client, msg.sender);
        if (!isClient && !access.isOperatorFor(job.provider, msg.sender)) revert NotParty(jobId);

        job.status = JobStatus.Disputed;
        _logBoth(job, ACT_DISPUTED, jobId, 0, _remaining(job));
        emit JobDisputed(jobId, isClient ? job.client : job.provider, reasonHash);
    }

    // ─── Arbiter ────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function resolve(uint256 jobId, uint16 providerBps) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Disputed);
        if (!access.isOperatorFor(job.arbiter, msg.sender)) revert NotArbiter(jobId);
        if (providerBps > BPS) revert InvalidBps(providerBps);

        uint256 remaining = _remaining(job);
        uint256 toProvider = (remaining * providerBps) / BPS;
        uint256 toClient = remaining - toProvider;
        job.released += toProvider;
        job.refunded += toClient;
        job.status = JobStatus.Resolved;

        uint256 fee = _fee(toProvider);
        _routeFee(job.provider, fee);
        _payOut(job.provider, toProvider - fee);
        _payOut(job.client, toClient);

        bool providerWon = providerBps >= BPS / 2;
        _recordReputation(job.provider, providerWon, toProvider);
        _recordReputation(job.client, !providerWon, toClient);
        _logBoth(job, ACT_RESOLVED, jobId, 0, remaining);
        emit JobResolved(jobId, providerBps, toProvider - fee, toClient, fee);
    }

    // ─── Anyone ─────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function refundExpired(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (job.status == JobStatus.Open) {
            if (block.timestamp <= _expiry(jobId, job)) revert DeadlineNotReached(jobId);
        } else if (job.status == JobStatus.Disputed) {
            if (block.timestamp <= uint256(job.deadline) + DISPUTE_GRACE) revert DeadlineNotReached(jobId);
        } else {
            revert WrongJobStatus(jobId, job.status);
        }

        uint256 remaining = _remaining(job);
        job.refunded += remaining;
        job.status = JobStatus.Expired;
        _payOut(job.client, remaining);
        _logBoth(job, ACT_EXPIRED, jobId, 0, remaining);
        emit JobExpired(jobId, remaining);
    }

    /// @inheritdoc IAgentEscrowV2
    function withdrawClaimable() external nonReentrant {
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        _token.safeTransfer(msg.sender, amount);
        emit ClaimableWithdrawn(msg.sender, amount);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _create(CreateParams calldata p) internal returns (uint256 jobId) {
        _requireAgentOrOperator(p.client);
        if (p.provider == address(0) || p.provider == p.client) revert InvalidParty();
        if (p.arbiter == p.client || p.arbiter == p.provider) revert InvalidParty();
        uint256 n = p.milestoneAmounts.length;
        if (n == 0 || n > MAX_MILESTONES) revert InvalidMilestones();
        if (p.deadline < block.timestamp + MIN_DURATION || p.deadline > block.timestamp + MAX_DURATION) {
            revert InvalidDeadline();
        }
        uint256 total = _sum(p.milestoneAmounts);

        _requireActive(p.provider);
        _consumeSpend(p.client, total);

        jobId = _jobCount++;
        Job storage job = _jobs[jobId];
        job.client = p.client;
        job.provider = p.provider;
        job.arbiter = p.arbiter;
        job.total = total;
        job.deadline = p.deadline;
        job.createdAt = uint48(block.timestamp);
        job.milestoneCount = uint8(n);
        job.termsHash = p.termsHash;

        Milestone[] storage ms = _milestones[jobId];
        for (uint256 i = 0; i < n; i++) {
            ms.push(
                Milestone({
                    amount: p.milestoneAmounts[i], deliverableHash: 0, submittedAt: 0, status: MilestoneStatus.Pending
                })
            );
        }
        _jobsOf[p.client].push(jobId);
        _jobsOf[p.provider].push(jobId);

        _token.safeTransferFrom(p.client, address(this), total);
        _logBoth(job, ACT_CREATED, jobId, 0, total);
        emit JobCreated(jobId, p.client, p.provider, p.arbiter, total, p.deadline);
    }

    function _approve(uint256 jobId, Job storage job, uint8 index, Milestone storage m) internal {
        m.status = MilestoneStatus.Approved;
        job.approvedCount += 1;
        job.released += m.amount;

        uint256 fee = _fee(m.amount);
        _routeFee(job.provider, fee);
        _payOut(job.provider, m.amount - fee);
        _recordReputation(job.provider, true, m.amount);
        _logBoth(job, ACT_APPROVED, jobId, index, m.amount);
        emit MilestoneApproved(jobId, index, m.amount - fee, fee);

        if (job.approvedCount == job.milestoneCount) {
            job.status = JobStatus.Completed;
            _recordReputation(job.client, true, job.total);
            _logBoth(job, ACT_COMPLETED, jobId, 0, job.total);
            emit JobCompleted(jobId);
        }
    }

    function _sum(uint256[] calldata amounts) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert InvalidMilestones();
            total += amounts[i];
        }
    }

    function _anySubmitted(uint256 jobId, Job storage job) internal view returns (bool) {
        Milestone[] storage ms = _milestones[jobId];
        for (uint8 i = 0; i < job.milestoneCount; i++) {
            if (ms[i].status == MilestoneStatus.Submitted) return true;
        }
        return false;
    }
}
