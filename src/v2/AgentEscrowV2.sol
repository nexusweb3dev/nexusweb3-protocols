// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";
import {IAgentAccess} from "./interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "./interfaces/IAgentEscrowV2.sol";

/// @title AgentEscrowV2
/// @notice Milestone escrow for agent-to-agent work. Client funds an offer (USDC pulled from the
///         client principal), provider accepts, submits deliverable hashes, client approves per
///         milestone. Optional party-chosen arbiter resolves disputes. Timeouts settle by rule:
///         submitted work pays the provider, unsubmitted work refunds the client. No NexusWeb3
///         owner action is ever required for a job to complete, refund, or resolve.
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
        _requireAccepted(jobId, job);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status == MilestoneStatus.Approved) revert WrongMilestoneStatus(jobId, index, m.status);
        _approve(jobId, job, index, m);
    }

    /// @inheritdoc IAgentEscrowV2
    function rejectMilestone(uint256 jobId, uint8 index, bytes32 reasonHash) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        _requireAccepted(jobId, job);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Submitted) revert WrongMilestoneStatus(jobId, index, m.status);
        // Once the review window closed the milestone is vested to the provider.
        if (block.timestamp > m.submittedAt + REVIEW_WINDOW) revert ReviewWindowClosed(jobId, index);

        m.status = MilestoneStatus.Pending;
        m.submittedAt = 0;
        m.rejections += 1;
        _logBoth(job, ACT_REJECTED, jobId, index, m.amount);
        emit MilestoneRejected(jobId, index, reasonHash);
    }

    /// @inheritdoc IAgentEscrowV2
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.client, msg.sender)) revert NotClient(jobId);
        // Once any milestone was ever submitted, the job can only end by approval, dispute or expiry.
        if (job.everSubmitted || job.approvedCount != 0) revert CannotCancel(jobId);

        job.status = JobStatus.Cancelled;
        job.refunded = job.total;
        _payOut(job.client, job.total);
        _logBoth(job, ACT_CANCELLED, jobId, 0, job.total);
        emit JobCancelled(jobId, job.total);
    }

    // ─── Provider ───────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function acceptJob(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        if (!access.isOperatorFor(job.provider, msg.sender)) revert NotProvider(jobId);
        if (job.acceptedAt != 0) revert AlreadyAccepted(jobId);
        if (block.timestamp > job.deadline) revert DeadlinePassed(jobId);
        _requireActive(job.provider);

        job.acceptedAt = uint48(block.timestamp);
        _logBoth(job, ACT_ACCEPTED, jobId, 0, job.total);
        emit JobAccepted(jobId);
    }

    /// @inheritdoc IAgentEscrowV2
    function submitMilestone(uint256 jobId, uint8 index, bytes32 deliverableHash) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        _requireAccepted(jobId, job);
        if (!access.isOperatorFor(job.provider, msg.sender)) revert NotProvider(jobId);
        if (block.timestamp > job.deadline) revert DeadlinePassed(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Pending) revert WrongMilestoneStatus(jobId, index, m.status);
        if (m.rejections >= MAX_REJECTIONS) revert TooManyRejections(jobId, index);

        m.status = MilestoneStatus.Submitted;
        m.deliverableHash = deliverableHash;
        m.submittedAt = uint48(block.timestamp);
        job.everSubmitted = true;
        _log(job.provider, ACT_SUBMITTED, jobId, index, m.amount);
        emit MilestoneSubmitted(jobId, index, deliverableHash);
    }

    /// @inheritdoc IAgentEscrowV2
    function claimApproval(uint256 jobId, uint8 index) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        _requireAccepted(jobId, job);
        if (!access.isOperatorFor(job.provider, msg.sender)) revert NotProvider(jobId);
        Milestone storage m = _milestone(jobId, job, index);
        if (m.status != MilestoneStatus.Submitted) revert WrongMilestoneStatus(jobId, index, m.status);
        uint48 claimableAt = m.submittedAt + uint48(REVIEW_WINDOW);
        if (block.timestamp <= claimableAt) revert ReviewWindowOpen(jobId, index, claimableAt);
        emit MilestoneClaimed(jobId, index);
        _approve(jobId, job, index, m);
    }

    // ─── Either party ───────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function dispute(uint256 jobId, bytes32 reasonHash) external nonReentrant {
        Job storage job = _job(jobId);
        _requireStatus(jobId, job, JobStatus.Open);
        _requireAccepted(jobId, job);
        if (job.arbiter == address(0)) revert NoArbiter(jobId);
        if (block.timestamp > _expiry(jobId, job)) revert DeadlinePassed(jobId);
        bool isClient = access.isOperatorFor(job.client, msg.sender);
        if (!isClient && !access.isOperatorFor(job.provider, msg.sender)) revert NotParty(jobId);

        job.status = JobStatus.Disputed;
        job.disputedAt = uint48(block.timestamp);
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

        (, uint256 fee) = _payProvider(job, toProvider);
        _payOut(job.client, toClient);

        // An even split is neutral; otherwise the side awarded the majority wins reputation.
        if (providerBps != BPS / 2 && _mayScore(job, remaining)) {
            bool providerWon = providerBps > BPS / 2;
            _recordReputation(job.provider, providerWon, toProvider);
            _recordReputation(job.client, !providerWon, toClient);
        }
        _logBoth(job, ACT_RESOLVED, jobId, 0, remaining);
        emit JobResolved(jobId, providerBps, toProvider - fee, toClient, fee);
    }

    // ─── Anyone ─────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function settleExpired(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (job.status == JobStatus.Open) {
            if (block.timestamp <= _expiry(jobId, job)) revert DeadlineNotReached(jobId);
        } else if (job.status == JobStatus.Disputed) {
            if (block.timestamp <= uint256(job.disputedAt) + DISPUTE_GRACE) revert DeadlineNotReached(jobId);
        } else {
            revert WrongJobStatus(jobId, job.status);
        }

        // Rule: every Submitted milestone is vested to the provider; everything else to the client.
        uint256 toProvider;
        Milestone[] storage ms = _milestones[jobId];
        for (uint8 i = 0; i < job.milestoneCount; i++) {
            if (ms[i].status != MilestoneStatus.Submitted) continue;
            ms[i].status = MilestoneStatus.Approved;
            job.approvedCount += 1;
            toProvider += ms[i].amount;
        }
        uint256 toClient = _remaining(job) - toProvider;
        job.released += toProvider;
        job.refunded += toClient;
        job.status = JobStatus.Expired;

        _payProvider(job, toProvider);
        _payOut(job.client, toClient);
        if (toProvider > 0 && _mayScore(job, toProvider)) _recordReputation(job.provider, true, toProvider);
        _logBoth(job, ACT_EXPIRED, jobId, 0, toProvider + toClient);
        emit JobExpired(jobId, toProvider, toClient);
    }

    /// @inheritdoc IAgentEscrowV2
    function withdrawClaimable(address account, address to) external nonReentrant {
        _requireAgentOrOperator(account);
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = _claimable[account];
        if (amount == 0) revert NothingToClaim();
        _claimable[account] = 0;
        _token.safeTransfer(to, amount);
        emit ClaimableWithdrawn(account, to, amount);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _create(CreateParams calldata p) internal returns (uint256 jobId) {
        _requireAgentOrOperator(p.client);
        _validateParties(p);
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
                    amount: p.milestoneAmounts[i],
                    deliverableHash: 0,
                    submittedAt: 0,
                    rejections: 0,
                    status: MilestoneStatus.Pending
                })
            );
        }
        _jobsOf[p.client].push(jobId);
        _jobsOf[p.provider].push(jobId);

        uint256 before = _token.balanceOf(address(this));
        _token.safeTransferFrom(p.client, address(this), total);
        uint256 received = _token.balanceOf(address(this)) - before;
        if (received != total) revert TokenAmountMismatch(total, received);

        _logBoth(job, ACT_CREATED, jobId, 0, total);
        emit JobCreated(jobId, p.client, p.provider, p.arbiter, total, p.deadline);
    }

    /// @dev Parties must be distinct, not this contract, and the arbiter must not be an operator of
    ///      either party (nor either party an operator of the arbiter) at creation time.
    function _validateParties(CreateParams calldata p) internal view {
        if (p.provider == address(0) || p.provider == p.client) revert InvalidParty();
        if (p.provider == address(this) || p.client == address(this) || p.arbiter == address(this)) {
            revert InvalidParty();
        }
        if (p.arbiter == p.client || p.arbiter == p.provider) revert InvalidParty();
        if (p.arbiter == address(0)) return;
        if (access.operatorExpiry(p.client, p.arbiter) != 0 || access.operatorExpiry(p.provider, p.arbiter) != 0) {
            revert InvalidParty();
        }
        if (access.operatorExpiry(p.arbiter, p.client) != 0 || access.operatorExpiry(p.arbiter, p.provider) != 0) {
            revert InvalidParty();
        }
    }

    function _approve(uint256 jobId, Job storage job, uint8 index, Milestone storage m) internal {
        m.status = MilestoneStatus.Approved;
        job.approvedCount += 1;
        job.released += m.amount;

        (uint256 net, uint256 fee) = _payProvider(job, m.amount);
        if (_mayScore(job, m.amount)) _recordReputation(job.provider, true, m.amount);
        _logBoth(job, ACT_APPROVED, jobId, index, m.amount);
        emit MilestoneApproved(jobId, index, net, fee);

        if (job.approvedCount == job.milestoneCount) {
            job.status = JobStatus.Completed;
            if (_mayScore(job, job.total)) _recordReputation(job.client, true, job.total);
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
}
