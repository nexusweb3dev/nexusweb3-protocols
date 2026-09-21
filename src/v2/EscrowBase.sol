// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OperatorGated} from "./OperatorGated.sol";
import {IAgentAccess} from "./interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "./interfaces/IAgentEscrowV2.sol";
import {IAgentReputationV2} from "./interfaces/IAgentReputationV2.sol";
import {IAgentAuditLogV2} from "./interfaces/IAgentAuditLogV2.sol";
import {IAgentKillSwitchV2} from "./interfaces/IAgentKillSwitchV2.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";

/// @title EscrowBase
/// @notice Storage, views, module hooks and safe payout logic for AgentEscrowV2.
///         Module addresses (reputation, audit log, kill switch, fee router) are optional; a zero
///         address disables that hook. Reputation and audit-log writes are best-effort (try/catch)
///         so a module fault can never lock funds. Fee routing is atomic and best-effort (fee parks
///         as owner-claimable on failure). Kill-switch calls are strict by design.
abstract contract EscrowBase is OperatorGated, Ownable, ReentrancyGuard, Pausable, IAgentEscrowV2 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 500; // 5% hard cap
    uint256 public constant BPS = 10_000;
    uint8 public constant MAX_MILESTONES = 20;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 365 days;
    /// @notice After deadline + grace, a still-disputed job can be refunded to the client by anyone.
    uint256 public constant DISPUTE_GRACE = 30 days;
    /// @notice A Submitted milestone the client neither approves nor rejects within this window can
    ///         be claimed by the provider. Submissions also extend the job expiry by this window.
    uint256 public constant REVIEW_WINDOW = 7 days;
    uint8 public constant REPUTATION_CATEGORY = 1; // ESCROW
    /// @notice Gas stipends forwarded to best-effort hooks. A call reverts with InsufficientGas if
    ///         the caller did not supply enough gas for the hook, so gas estimation can never
    ///         converge on a cheaper path that silently drops the reputation/audit write.
    uint256 public constant HOOK_GAS_LOG = 300_000;
    uint256 public constant HOOK_GAS_REPUTATION = 200_000;
    uint256 public constant HOOK_GAS_FEE = 250_000;

    bytes32 internal constant ACT_CREATED = "ESCROW_JOB_CREATED";
    bytes32 internal constant ACT_SUBMITTED = "ESCROW_MILESTONE_SUBMITTED";
    bytes32 internal constant ACT_APPROVED = "ESCROW_MILESTONE_APPROVED";
    bytes32 internal constant ACT_REJECTED = "ESCROW_MILESTONE_REJECTED";
    bytes32 internal constant ACT_COMPLETED = "ESCROW_JOB_COMPLETED";
    bytes32 internal constant ACT_CANCELLED = "ESCROW_JOB_CANCELLED";
    bytes32 internal constant ACT_DISPUTED = "ESCROW_JOB_DISPUTED";
    bytes32 internal constant ACT_RESOLVED = "ESCROW_JOB_RESOLVED";
    bytes32 internal constant ACT_EXPIRED = "ESCROW_JOB_EXPIRED";

    IERC20 internal immutable _token;
    uint256 internal _feeBps;
    IAgentReputationV2 internal _reputation;
    IAgentAuditLogV2 internal _auditLog;
    IAgentKillSwitchV2 internal _killSwitch;
    IFeeRouter internal _feeRouter;

    uint256 internal _jobCount;
    mapping(uint256 jobId => Job) internal _jobs;
    mapping(uint256 jobId => Milestone[]) internal _milestones;
    mapping(address account => uint256[]) internal _jobsOf;
    mapping(address account => uint256) internal _claimable;

    constructor(IAgentAccess access_, IERC20 token_, address owner_) OperatorGated(access_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        _token = token_;
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function getJob(uint256 jobId) external view returns (Job memory) {
        if (jobId >= _jobCount) revert JobNotFound(jobId);
        return _jobs[jobId];
    }

    /// @inheritdoc IAgentEscrowV2
    function getMilestones(uint256 jobId) external view returns (Milestone[] memory) {
        if (jobId >= _jobCount) revert JobNotFound(jobId);
        return _milestones[jobId];
    }

    /// @inheritdoc IAgentEscrowV2
    function getJobsOf(address account, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = _jobsOf[account];
        uint256 len = all.length;
        if (offset >= len || limit == 0) return new uint256[](0);
        uint256 n = len - offset;
        if (n > limit) n = limit;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = all[offset + i];
        }
    }

    /// @inheritdoc IAgentEscrowV2
    function jobCountOf(address account) external view returns (uint256) {
        return _jobsOf[account].length;
    }

    /// @inheritdoc IAgentEscrowV2
    function jobCount() external view returns (uint256) {
        return _jobCount;
    }

    /// @inheritdoc IAgentEscrowV2
    function expiryOf(uint256 jobId) external view returns (uint48) {
        Job storage job = _job(jobId);
        return _expiry(jobId, job);
    }

    /// @inheritdoc IAgentEscrowV2
    function claimable(address account) external view returns (uint256) {
        return _claimable[account];
    }

    /// @inheritdoc IAgentEscrowV2
    function feeBps() external view returns (uint256) {
        return _feeBps;
    }

    /// @inheritdoc IAgentEscrowV2
    function paymentToken() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IAgentEscrowV2
    function reputation() external view returns (address) {
        return address(_reputation);
    }

    /// @inheritdoc IAgentEscrowV2
    function auditLog() external view returns (address) {
        return address(_auditLog);
    }

    /// @inheritdoc IAgentEscrowV2
    function killSwitch() external view returns (address) {
        return address(_killSwitch);
    }

    /// @inheritdoc IAgentEscrowV2
    function feeRouter() external view returns (address) {
        return address(_feeRouter);
    }

    // ─── Owner ──────────────────────────────────────────────────────────

    /// @inheritdoc IAgentEscrowV2
    function setFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        if (newBps > 0 && address(_feeRouter) == address(0)) revert ZeroAddress();
        uint256 old = _feeBps;
        _feeBps = newBps;
        emit FeeBpsUpdated(old, newBps);
    }

    /// @inheritdoc IAgentEscrowV2
    function setModules(
        address reputation_,
        address auditLog_,
        address killSwitch_,
        address feeRouter_
    )
        external
        onlyOwner
    {
        if (feeRouter_ == address(0) && _feeBps > 0) revert ZeroAddress();
        _reputation = IAgentReputationV2(reputation_);
        _auditLog = IAgentAuditLogV2(auditLog_);
        _killSwitch = IAgentKillSwitchV2(killSwitch_);
        _feeRouter = IFeeRouter(feeRouter_);
        emit ModulesUpdated(reputation_, auditLog_, killSwitch_, feeRouter_);
    }

    /// @notice Pause new job creation. Approvals, refunds and withdrawals always keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume job creation.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal: module hooks ─────────────────────────────────────────

    function _consumeSpend(address agent, uint256 amount) internal {
        if (address(_killSwitch) != address(0)) _killSwitch.consume(agent, amount);
    }

    function _requireActive(address agent) internal view {
        if (address(_killSwitch) != address(0) && !_killSwitch.isActive(agent)) revert ProviderInactive(agent);
    }

    function _recordReputation(address agent, bool positive, uint256 value) internal {
        if (address(_reputation) == address(0)) return;
        _requireGas(HOOK_GAS_REPUTATION);
        try _reputation.recordInteraction{gas: HOOK_GAS_REPUTATION}(agent, positive, REPUTATION_CATEGORY, value) {}
            catch {}
    }

    function _log(address agent, bytes32 actionType, uint256 jobId, uint8 index, uint256 value) internal {
        if (address(_auditLog) == address(0)) return;
        bytes32 dataHash = keccak256(abi.encode(jobId, index));
        _requireGas(HOOK_GAS_LOG);
        try _auditLog.log{gas: HOOK_GAS_LOG}(agent, actionType, dataHash, value) {} catch {}
    }

    function _logBoth(Job storage job, bytes32 actionType, uint256 jobId, uint8 index, uint256 value) internal {
        _log(job.client, actionType, jobId, index, value);
        _log(job.provider, actionType, jobId, index, value);
    }

    // ─── Internal: money ────────────────────────────────────────────────

    function _fee(uint256 amount) internal view returns (uint256) {
        if (_feeBps == 0) return 0;
        return amount.mulDiv(_feeBps, BPS, Math.Rounding.Floor);
    }

    /// @dev Best-effort fee routing. The transfer+route pair runs atomically via a self-call; if it
    ///      reverts (router revoked, paused, misconfigured) the fee is parked as claimable by the
    ///      owner and the provider payout proceeds. A fee-side fault can never freeze payouts.
    function _routeFee(address agent, uint256 fee) internal {
        if (fee == 0) return;
        _requireGas(HOOK_GAS_FEE);
        try this.routeFeeSelf{gas: HOOK_GAS_FEE}(agent, fee) {}
        catch {
            _claimable[owner()] += fee;
            emit ClaimableAdded(owner(), fee);
        }
    }

    /// @notice Internal step of fee routing, exposed only so it can run under try/catch.
    function routeFeeSelf(address agent, uint256 fee) external {
        if (msg.sender != address(this)) revert NotSelf();
        _token.safeTransfer(address(_feeRouter), fee);
        _feeRouter.route(agent, fee);
    }

    /// @dev Transfer with claimable fallback so a failing recipient (e.g. blacklisted) never blocks a job.
    function _payOut(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = address(_token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        bool success = ok && (data.length == 0 || abi.decode(data, (bool)));
        if (success) return;
        _claimable[to] += amount;
        emit ClaimableAdded(to, amount);
    }

    // ─── Internal: guards ───────────────────────────────────────────────

    /// @dev EIP-150 forwards at most 63/64 of remaining gas; make sure the full stipend arrives.
    function _requireGas(uint256 stipend) internal view {
        uint256 needed = stipend + stipend / 63 + 5000;
        if (gasleft() < needed) revert InsufficientGas(needed);
    }

    function _job(uint256 jobId) internal view returns (Job storage job) {
        if (jobId >= _jobCount) revert JobNotFound(jobId);
        job = _jobs[jobId];
    }

    function _requireStatus(uint256 jobId, Job storage job, JobStatus expected) internal view {
        if (job.status != expected) revert WrongJobStatus(jobId, job.status);
    }

    function _milestone(uint256 jobId, Job storage job, uint8 index) internal view returns (Milestone storage) {
        if (index >= job.milestoneCount) revert MilestoneNotFound(jobId, index);
        return _milestones[jobId][index];
    }

    function _remaining(Job storage job) internal view returns (uint256) {
        return job.total - job.released - job.refunded;
    }

    /// @dev max(deadline, submittedAt + REVIEW_WINDOW over currently Submitted milestones).
    function _expiry(uint256 jobId, Job storage job) internal view returns (uint48 t) {
        t = job.deadline;
        Milestone[] storage ms = _milestones[jobId];
        for (uint8 i = 0; i < job.milestoneCount; i++) {
            if (ms[i].status != MilestoneStatus.Submitted) continue;
            uint48 claimableAt = ms[i].submittedAt + uint48(REVIEW_WINDOW);
            if (claimableAt > t) t = claimableAt;
        }
    }
}
