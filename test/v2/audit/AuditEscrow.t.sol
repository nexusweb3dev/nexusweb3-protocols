// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {
    FailingToken,
    MockAuditLog,
    MockFeeRouter,
    MockKillSwitch,
    MockReputation,
    PermitToken
} from "../mocks/MockModules.sol";
import {AgentAccess} from "../../../src/v2/AgentAccess.sol";
import {AgentEscrowV2} from "../../../src/v2/AgentEscrowV2.sol";
import {IAgentAccess} from "../../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "../../../src/v2/interfaces/IAgentEscrowV2.sol";

/// @notice Reputation module that tries to re-enter the escrow while `_approve` is mid-flight.
///         Used to prove the reentrancy guards on the state transitions (F-6).
contract ReentrantReputation {
    AgentEscrowV2 public escrow;
    uint256 public targetJob;
    bool public armed;
    bool public attempted;
    bool public reentered;

    function arm(AgentEscrowV2 escrow_, uint256 jobId) external {
        escrow = escrow_;
        targetJob = jobId;
        armed = true;
    }

    function recordInteraction(address, bool, uint8, uint256) external {
        if (!armed) return;
        armed = false;
        attempted = true;
        // dispute() is nonReentrant, so this must be rejected while approveMilestone holds the lock.
        try escrow.dispute(targetJob, keccak256("reentrant")) {
            reentered = true;
        } catch {}
    }
}

/// @notice Fee router that tries every drain vector from inside `routeFeeSelf`.
contract PredatoryFeeRouter {
    AgentEscrowV2 public escrow;
    bool public withdrawBlocked;
    bool public createBlocked;
    bool public routeSelfBlocked;

    function arm(AgentEscrowV2 escrow_) external {
        escrow = escrow_;
    }

    function route(address, uint256) external {
        try escrow.withdrawClaimable(address(this), address(this)) {}
        catch {
            withdrawBlocked = true;
        }
        try escrow.routeFeeSelf(address(this), 1) {}
        catch {
            routeSelfBlocked = true;
        }
        IAgentEscrowV2.CreateParams memory p;
        p.client = address(this);
        try escrow.createJob(p) {}
        catch {
            createBlocked = true;
        }
    }
}

/// @notice Pre-deployment security audit PoCs for EscrowBase / AgentEscrowV2, migrated to the fixed
///         contract. Tests marked `FIXED: <id>` keep the original exploit scenario and now assert the
///         guarantee the fix provides; tests marked `SAFE` lock in properties that always held.
contract AuditEscrowTest is Test {
    ERC20Mock usdc;
    AgentAccess access;
    AgentEscrowV2 escrow;

    MockReputation reputation;
    MockAuditLog auditLog;
    MockKillSwitch killSwitch;
    MockFeeRouter feeRouter;

    address owner = makeAddr("auditOwner");
    address client = makeAddr("auditClient");
    address provider = makeAddr("auditProvider");
    address arbiter = makeAddr("auditArbiter");
    address keeper = makeAddr("auditKeeper");

    uint256 constant M = 100_000_000; // $100 USDC (6dp)
    uint256 constant MINT = 1_000_000_000_000;
    uint256 constant FEE_BPS = 250;
    uint256 constant REVIEW_WINDOW = 7 days;
    uint256 constant DISPUTE_GRACE = 30 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        access = new AgentAccess();
        escrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(usdc)), owner);

        reputation = new MockReputation();
        auditLog = new MockAuditLog();
        killSwitch = new MockKillSwitch();
        feeRouter = new MockFeeRouter();

        usdc.mint(client, MINT);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _amounts(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = M;
        }
    }

    function _params(
        address client_,
        address provider_,
        address arbiter_,
        uint256 n,
        uint48 deadline
    )
        internal
        pure
        returns (IAgentEscrowV2.CreateParams memory)
    {
        return IAgentEscrowV2.CreateParams({
            client: client_,
            provider: provider_,
            arbiter: arbiter_,
            milestoneAmounts: _amounts(n),
            deadline: deadline,
            termsHash: keccak256("terms")
        });
    }

    function _create(address arbiter_, uint256 n, uint48 deadline) internal returns (uint256 jobId) {
        vm.prank(client);
        return escrow.createJob(_params(client, provider, arbiter_, n, deadline));
    }

    /// @dev createJob is only an offer now; the provider must bind itself before any work flows.
    function _createAccepted(address arbiter_, uint256 n, uint48 deadline) internal returns (uint256 jobId) {
        jobId = _create(arbiter_, n, deadline);
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function _shortDeadline() internal view returns (uint48) {
        return uint48(block.timestamp + 1 hours);
    }

    function _wire() internal {
        vm.prank(owner);
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
        vm.prank(owner);
        escrow.setFeeBps(FEE_BPS);
    }

    /// @dev Second escrow over a token whose `transfer` returns false for blocked recipients,
    ///      the closest local model of a USDC blacklist entry.
    function _failingSetup() internal returns (FailingToken token, AgentEscrowV2 failEscrow) {
        token = new FailingToken();
        failEscrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(failEscrow), type(uint256).max);
    }

    function _createOn(AgentEscrowV2 target, address arbiter_, uint256 n) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = target.createJob(_params(client, provider, arbiter_, n, _shortDeadline()));
        vm.prank(provider);
        target.acceptJob(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-1 (High, FIXED) — claimApproval and settleExpired used to unlock in the same
    // second and pay opposite parties, so a silent client could front-run the provider's
    // claim and refund a milestone the review window had already vested. settleExpired
    // now pays every Submitted milestone to the provider, so the two paths agree.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-1
    /// @dev The fix guarantees both unlock paths settle a Submitted milestone the same way, so
    ///      landing first in the block no longer decides who is paid.
    function test_F1_settleExpiredAndClaimApprovalUnlockInSameSecond() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable"));

        uint48 expiry = escrow.expiryOf(jobId);
        assertEq(expiry, uint48(block.timestamp + REVIEW_WINDOW), "expiry == submittedAt + REVIEW_WINDOW");

        // At expiry itself neither side can act.
        vm.warp(expiry);
        vm.prank(provider);
        vm.expectRevert();
        escrow.claimApproval(jobId, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);

        // expiry + 1: both are legal, and both pay the provider.
        vm.warp(uint256(expiry) + 1);
        uint256 snap = vm.snapshotState();
        vm.prank(provider);
        escrow.claimApproval(jobId, 0);
        assertEq(usdc.balanceOf(provider), M, "claimApproval pays the vested milestone");

        vm.revertToState(snap);
        vm.prank(keeper);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(provider), M, "settleExpired pays the same vested milestone");
    }

    // FIXED: F-1
    /// @dev The fix guarantees "client silence = acceptance": whoever settles, the Submitted
    ///      milestone vests to the provider and only unsubmitted work returns to the client.
    function test_F1_silentAcceptanceCannotBeFrontRun() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable"));

        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        // Client (or a searcher it pays) front-runs the provider's claimApproval.
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, M, M);
        vm.prank(keeper);
        escrow.settleExpired(jobId);

        // The provider cannot claim any more, because it has already been paid.
        vm.prank(provider);
        vm.expectRevert();
        escrow.claimApproval(jobId, 0);

        assertEq(usdc.balanceOf(provider), M, "provider keeps the milestone the client silently accepted");
        assertEq(usdc.balanceOf(client), MINT - M, "client only recovers the unsubmitted milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-2 (High, FIXED) — the Disputed settlement branch measured DISPUTE_GRACE from
    // `job.deadline`, so a dispute could make a job refundable EARLIER than leaving it
    // Open and hand submitted work back to the client. The grace now runs from
    // `disputedAt`, and settlement vests Submitted milestones to the provider.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-2
    /// @dev The fix guarantees a dispute always buys the arbiter a full DISPUTE_GRACE measured from
    ///      the dispute itself, and never converts delivered work into a client refund.
    function test_F2_disputedClockRunsFromDisputeAndVestsSubmittedWork() public {
        uint48 deadline = _shortDeadline();
        uint256 jobId = _createAccepted(arbiter, 2, deadline);

        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable"));

        // Client disputes at the last legal second, hoping to stall past the provider's claim.
        vm.warp(uint256(escrow.expiryOf(jobId)));
        vm.prank(client);
        escrow.dispute(jobId, keccak256("stall"));

        uint256 disputedAt = escrow.getJob(jobId).disputedAt;
        assertEq(disputedAt, block.timestamp, "grace is anchored to the dispute");

        // Nothing settles before the arbiter's 30 days are up, however long ago the deadline was.
        vm.warp(disputedAt + DISPUTE_GRACE);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);

        vm.warp(disputedAt + DISPUTE_GRACE + 1);
        vm.prank(keeper);
        escrow.settleExpired(jobId);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(usdc.balanceOf(provider), M, "the disputed-away milestone still settles to the provider");
        assertEq(usdc.balanceOf(client), MINT - M, "client recovers only the unsubmitted milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-3 / E-02 (Medium, FIXED) — submitMilestone had no deadline check and every
    // submission pushed `_expiry` out by REVIEW_WINDOW, so a provider could re-arm the
    // expiry forever. Submissions now stop at the deadline and after MAX_REJECTIONS.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-3
    /// @dev The fix guarantees expiry can never exceed deadline + REVIEW_WINDOW, so the deposit is
    ///      always recoverable even with no arbiter seated.
    function test_F3_providerResubmitLoopIsBounded_noArbiter() public {
        uint48 deadline = uint48(block.timestamp + 30 days);
        uint256 jobId = _createAccepted(address(0), 3, deadline);

        for (uint256 round = 0; round < 3; round++) {
            vm.prank(provider);
            escrow.submitMilestone(jobId, 0, keccak256(abi.encode(round)));
            assertLe(
                uint256(escrow.expiryOf(jobId)),
                uint256(deadline) + REVIEW_WINDOW,
                "expiry never passes deadline + one review window"
            );

            // The client rejects inside the review window; the provider resubmits next round.
            vm.warp(block.timestamp + 1 days);
            vm.prank(client);
            escrow.rejectMilestone(jobId, 0, keccak256("no"));
        }

        // Fourth attempt: the rejection cap closes the loop.
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TooManyRejections.selector, jobId, uint8(0)));
        escrow.submitMilestone(jobId, 0, keccak256("again"));

        // And no milestone can be submitted at all once the deadline passes.
        vm.warp(uint256(deadline) + 1);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.submitMilestone(jobId, 1, keccak256("late"));

        // The client gets the whole deposit back without ever needing an arbiter.
        vm.prank(keeper);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), MINT, "deposit recovered, not trapped");
        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-4 (Medium, FIXED) — withdrawClaimable paid msg.sender and offered no destination,
    // so the very recipient the claimable ledger exists for (a blacklisted address) could
    // never reach its funds. It now takes `(account, to)` and accepts an operator caller.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-4
    /// @dev The fix guarantees parked funds always have an exit: the principal or its operator picks
    ///      a destination the token will accept.
    function test_F4_blockedRecipientWithdrawsClaimableToAFreshAddress() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        uint256 jobId = _createOn(failEscrow, arbiter, 1);

        token.setBlocked(provider, true); // simulate a USDC blacklist entry
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);

        assertEq(failEscrow.claimable(provider), M, "payout parked as claimable");
        assertEq(token.balanceOf(address(failEscrow)), M, "tokens still sit in the escrow");

        // The blocked principal routes its own parked funds somewhere the token accepts.
        address rescue = makeAddr("providerRescue");
        vm.prank(provider);
        vm.expectEmit(true, true, false, true, address(failEscrow));
        emit IAgentEscrowV2.ClaimableWithdrawn(provider, rescue, M);
        failEscrow.withdrawClaimable(provider, rescue);

        assertEq(token.balanceOf(rescue), M, "parked funds recovered");
        assertEq(failEscrow.claimable(provider), 0);
        assertEq(token.balanceOf(address(failEscrow)), 0);

        // An operator of the provider can do the same on its behalf.
        uint256 jobId2 = _createOn(failEscrow, arbiter, 1);
        vm.prank(client);
        failEscrow.approveMilestone(jobId2, 0);

        address providerOp = makeAddr("providerOp");
        vm.prank(provider);
        access.authorizeOperator(providerOp, type(uint48).max);
        vm.prank(providerOp);
        failEscrow.withdrawClaimable(provider, rescue);
        assertEq(token.balanceOf(rescue), 2 * M, "operator rescued the second payout too");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-5 (Medium, FIXED) — _create only checked that the arbiter was not literally a
    // party, so a client could seat one of its own hot keys as "neutral" arbiter and claw
    // back delivered work via dispute() + resolve(0). Operator relationships in either
    // direction are now rejected at creation.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-5
    /// @dev The fix guarantees no address that is an operator of a party (or whose operator is a
    ///      party) can be seated as arbiter, so the dispute path cannot be self-dealt.
    function test_F5_clientControlledArbiterIsRejectedAtCreation() public {
        address shamArbiter = makeAddr("shamArbiter");
        // The sham arbiter is simply another hot key of the client.
        vm.prank(client);
        access.authorizeOperator(shamArbiter, type(uint48).max);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidParty.selector));
        escrow.createJob(_params(client, provider, shamArbiter, 1, _shortDeadline()));

        // A provider-side hot key is rejected the same way.
        address providerKey = makeAddr("providerKey");
        vm.prank(provider);
        access.authorizeOperator(providerKey, type(uint48).max);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidParty.selector));
        escrow.createJob(_params(client, provider, providerKey, 1, _shortDeadline()));

        // And so is the mirrored relationship: an arbiter that operates the client.
        address bossArbiter = makeAddr("bossArbiter");
        vm.prank(bossArbiter);
        access.authorizeOperator(client, type(uint48).max);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidParty.selector));
        escrow.createJob(_params(client, provider, bossArbiter, 1, _shortDeadline()));

        // An unrelated arbiter is still accepted.
        uint256 jobId = _createAccepted(arbiter, 1, _shortDeadline());
        assertEq(escrow.getJob(jobId).arbiter, arbiter);
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-6 (Low, FIXED) — submitMilestone / rejectMilestone / dispute carried no
    // nonReentrant, so a fallible module that was also an operator could flip an Open job
    // to Disputed from inside _approve. Every state transition is guarded now.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-6
    /// @dev The fix guarantees no module callback can move a job through the state machine while an
    ///      entrypoint holds the reentrancy lock.
    function test_F6_maliciousModuleCannotReenterDisputeDuringApprove() public {
        ReentrantReputation evil = new ReentrantReputation();
        vm.prank(owner);
        escrow.setModules(address(evil), address(0), address(0), address(0));

        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        // The module doubles as an authorized operator of the provider.
        vm.prank(provider);
        access.authorizeOperator(address(evil), type(uint48).max);
        evil.arm(escrow, jobId);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertTrue(evil.attempted(), "the module did try to re-enter");
        assertFalse(evil.reentered(), "dispute() was rejected by the reentrancy guard");
        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Open), "approval left the job Open");
        assertEq(job.released, M, "the milestone was still paid");
        assertEq(usdc.balanceOf(address(escrow)), job.total - job.released - job.refunded);
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-7 (Low, FIXED) — _create accepted provider == address(escrow), whose payout was a
    // self-transfer that "succeeded" and stranded the money. The escrow can no longer be
    // seated as any party.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-7
    /// @dev The fix guarantees `balance == Σ owed + Σ claimable` cannot be broken by seating the
    ///      escrow itself as a party.
    function test_F7_escrowAsPartyIsRejected() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidParty.selector));
        escrow.createJob(_params(client, address(escrow), address(0), 1, _shortDeadline()));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidParty.selector));
        escrow.createJob(_params(client, provider, address(escrow), 1, _shortDeadline()));

        assertEq(escrow.jobCount(), 0, "no job was created");
        assertEq(usdc.balanceOf(address(escrow)), 0, "no funds were pulled");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-10 (Low, FIXED) — an even arbiter split used to be scored as a win for one side.
    // resolve(5000) is now reputation-neutral.
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: F-10
    /// @dev The fix guarantees a 50/50 resolution records nothing for either party, while a decisive
    ///      split still records exactly one winner and one loser.
    function test_F10_evenSplitResolveIsReputationNeutral() public {
        _wire();

        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);
        assertEq(reputation.callCount(), 0, "an even split scores neither party");

        uint256 jobId2 = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(client);
        escrow.dispute(jobId2, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(jobId2, 10_000);

        assertEq(reputation.callCount(), 2, "a decisive split scores both parties once");
        assertTrue(reputation.lastPositiveOf(provider), "provider won");
        assertFalse(reputation.lastPositiveOf(client), "client lost");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-8 (Informational) — events report a payout even when the transfer failed and the
    // amount was parked. An indexer reading MilestoneApproved alone credits the provider
    // with funds it never received. Accepted: ClaimableAdded is emitted alongside.
    // ═══════════════════════════════════════════════════════════════════

    function test_F8_milestoneApprovedEventReportsUnpaidPayout() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        uint256 jobId = _createOn(failEscrow, arbiter, 1);
        token.setBlocked(provider, true);

        vm.expectEmit(true, true, false, true, address(failEscrow));
        emit IAgentEscrowV2.MilestoneApproved(jobId, 0, M, 0);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);

        assertEq(token.balanceOf(provider), 0, "event claims a payout the provider never received");
        assertEq(failEscrow.claimable(provider), M);
    }

    // ═══════════════════════════════════════════════════════════════════
    // F-9 (Informational) — gas floor verification. Measures the real gas the final
    // approveMilestone needs so the 1.5M figure in MIGRATION.md L37 can be confirmed,
    // and shows that settleExpired (permissionless, keeper-called) carries an
    // undocumented gas floor whenever the audit log module is wired.
    // ═══════════════════════════════════════════════════════════════════

    function test_F9_gasFloors_lastApproveAndSettleExpired() public {
        _wire();

        // (a) completing approveMilestone: fee hook + 2 reputation writes + 4 audit logs.
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        uint256 approveFloor = _minGas(client, abi.encodeCall(IAgentEscrowV2.approveMilestone, (jobId, 1)));
        emit log_named_uint("min gas limit for completing approveMilestone", approveFloor);

        // (b) settleExpired: permissionless keeper path, 2 audit logs, floor NOT documented.
        uint256 job2 = _createAccepted(arbiter, 2, _shortDeadline());
        vm.warp(uint256(escrow.expiryOf(job2)) + 1);
        uint256 settleFloor = _minGas(keeper, abi.encodeCall(IAgentEscrowV2.settleExpired, (job2)));
        emit log_named_uint("min gas limit for settleExpired", settleFloor);

        // The documented 1,500,000 guidance in MIGRATION.md L37 does cover both paths.
        assertLt(approveFloor, 1_500_000, "approve floor exceeds the documented 1.5M guidance");
        assertLt(settleFloor, 1_500_000, "settle floor exceeds the documented 1.5M guidance");
        // But settleExpired still needs far more than a plain ERC20 transfer, which the guide omits.
        assertGt(settleFloor, 300_000, "settleExpired carries an undocumented gas floor");
    }

    /// @dev Binary-searches the smallest gas limit for which `data` succeeds against the escrow.
    function _minGas(address caller, bytes memory data) internal returns (uint256) {
        uint256 lo = 21_000;
        uint256 hi = 3_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(caller);
            (bool ok,) = address(escrow).call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    // ═══════════════════════════════════════════════════════════════════
    // SAFE checks — properties that hold and are asserted here so the lead has coverage.
    // ═══════════════════════════════════════════════════════════════════

    /// @dev acceptJob is the gate: nothing can be submitted, approved or disputed on a bare offer.
    function test_SAFE_offerIsInertUntilTheProviderAccepts() public {
        uint256 jobId = _create(arbiter, 2, _shortDeadline());

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.submitMilestone(jobId, 0, keccak256("d"));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.approveMilestone(jobId, 0);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.dispute(jobId, bytes32(0));

        // The client can still withdraw the offer, and the provider cannot accept twice.
        vm.prank(provider);
        escrow.acceptJob(jobId);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.AlreadyAccepted.selector, jobId));
        escrow.acceptJob(jobId);
    }

    /// @dev cancelJob is closed for good once any milestone was ever submitted.
    function test_SAFE_cancelIsBlockedOnceAnythingWasSubmitted() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("work"));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, keccak256("pretext"));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        escrow.cancelJob(jobId);
        assertTrue(escrow.getJob(jobId).everSubmitted, "everSubmitted is sticky");
    }

    /// @dev Parked fee and routed fee are mutually exclusive: routeFeeSelf is atomic.
    function test_SAFE_feeIsEitherRoutedOrParked_neverBoth() public {
        _wire();
        feeRouter.setShouldRevert(true);
        uint256 jobId = _createAccepted(arbiter, 1, _shortDeadline());
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        uint256 fee = M * FEE_BPS / 10_000;
        assertEq(escrow.claimable(owner), fee, "fee parked for owner");
        assertEq(usdc.balanceOf(address(feeRouter)), 0, "transfer rolled back with the route call");
        assertEq(usdc.balanceOf(provider), M - fee);
        assertEq(usdc.balanceOf(address(escrow)), fee);
    }

    /// @dev A malicious fee router receives only `fee` and cannot re-enter any guarded path:
    ///      the ReentrancyGuard status survives the `this.routeFeeSelf` self-call.
    function test_SAFE_maliciousFeeRouterCannotDrainEscrow() public {
        PredatoryFeeRouter evil = new PredatoryFeeRouter();
        evil.arm(escrow);
        vm.prank(owner);
        escrow.setModules(address(0), address(0), address(0), address(evil));
        vm.prank(owner);
        escrow.setFeeBps(FEE_BPS);

        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        uint256 fee = M * FEE_BPS / 10_000;
        assertTrue(evil.withdrawBlocked(), "withdrawClaimable blocked by the guard");
        assertTrue(evil.createBlocked(), "createJob blocked by the guard");
        assertTrue(evil.routeSelfBlocked(), "routeFeeSelf blocked by the self check");
        assertEq(usdc.balanceOf(address(evil)), fee, "router received exactly the fee, nothing more");
        assertEq(usdc.balanceOf(address(escrow)), M, "the remaining milestone is untouched");
    }

    /// @dev routeFeeSelf is unreachable by anyone but the escrow itself.
    function test_SAFE_routeFeeSelfIsSelfOnly() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotSelf.selector));
        escrow.routeFeeSelf(provider, 1);
    }

    /// @dev feeBps > 0 with a zero fee router is unreachable in both orderings.
    function test_SAFE_feeBpsCannotOutliveTheRouter() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ZeroAddress.selector));
        escrow.setFeeBps(FEE_BPS);

        _wire();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ZeroAddress.selector));
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(0));
        assertEq(escrow.feeBps(), FEE_BPS);
    }

    /// @dev createJob for a third party is blocked even when that party has an open allowance.
    function test_SAFE_cannotCreateJobSpendingAnotherAgentsAllowance() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        // client has an unlimited allowance to the escrow.
        escrow.createJob(_params(client, attacker, address(0), 1, _shortDeadline()));
    }

    /// @dev A milestone can never be approved twice, so approvedCount cannot pass milestoneCount.
    function test_SAFE_noDoubleApprovalOrApprovedCountDrift() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        vm.prank(client);
        vm.expectRevert();
        escrow.approveMilestone(jobId, 0);
        vm.prank(provider);
        vm.expectRevert();
        escrow.claimApproval(jobId, 0);
        assertEq(escrow.getJob(jobId).approvedCount, 1);
    }

    /// @dev resolve at both bps extremes settles exactly `remaining`, fee only on the provider leg.
    function testFuzz_SAFE_resolveConservesRemainingAndFeesOnlyProvider(uint16 rawBps) public {
        uint16 bps = uint16(bound(rawBps, 0, 10_000));
        _wire();
        uint256 jobId = _createAccepted(arbiter, 3, _shortDeadline());
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(jobId, bps);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released + job.refunded, job.total, "remaining fully settled");
        uint256 toProvider = (2 * M * bps) / 10_000;
        uint256 toClient = 2 * M - toProvider;
        uint256 fee = toProvider * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(client), MINT - 3 * M + toClient, "no fee taken from the client leg");
        assertEq(usdc.balanceOf(provider), (M - M * FEE_BPS / 10_000) + toProvider - fee);
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow fully drained of this job");
    }

    /// @dev A strict kill switch can block new jobs but can never touch funds already escrowed.
    function test_SAFE_killSwitchFaultCannotLockExistingJobs() public {
        _wire();
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        killSwitch.setConsumeShouldRevert(true);
        killSwitch.setInactive(provider, true);

        vm.prank(client);
        vm.expectRevert();
        escrow.createJob(_params(client, provider, arbiter, 1, _shortDeadline()));

        // Existing job still settles normally.
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);
        vm.prank(keeper);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @dev A harvested permit signature cannot be redirected: _create still gates on the client.
    ///      The attacker's front-run merely pre-sets the allowance, and the victim's job still works.
    function test_SAFE_permitFrontRunCannotRedirectOrGriefTheJob() public {
        PermitToken ptoken = new PermitToken();
        AgentEscrowV2 pEscrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(ptoken)), owner);
        (address signer, uint256 pk) = makeAddrAndKey("permitClient");
        ptoken.mint(signer, MINT);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                ptoken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(pEscrow),
                        M,
                        ptoken.nonces(signer),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        IAgentEscrowV2.CreateParams memory p = _params(signer, provider, address(0), 1, _shortDeadline());

        // An attacker cannot reuse the signature to open a job against the signer.
        address attacker = makeAddr("permitAttacker");
        vm.prank(attacker);
        vm.expectRevert();
        pEscrow.createJobWithPermit(p, deadline, v, r, s);

        // Front-running the permit alone only pre-sets the allowance; the signer's call still works.
        vm.prank(attacker);
        ptoken.permit(signer, address(pEscrow), M, deadline, v, r, s);
        vm.prank(signer);
        uint256 jobId = pEscrow.createJobWithPermit(p, deadline, v, r, s);
        assertEq(ptoken.balanceOf(address(pEscrow)), M);
        assertEq(pEscrow.getJob(jobId).total, M);
        assertEq(ptoken.allowance(signer, address(pEscrow)), 0, "no residual allowance");
    }

    /// @dev dispute and settleExpired never overlap on an Open job: <= expiry vs > expiry.
    function test_SAFE_disputeAndSettleWindowsDoNotOverlap() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        uint48 expiry = escrow.expiryOf(jobId);

        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);

        vm.warp(uint256(expiry) + 1);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.dispute(jobId, bytes32(0));
        vm.prank(keeper);
        escrow.settleExpired(jobId);
    }

    /// @dev Pausing cannot strand funds: every settlement path stays open.
    function test_SAFE_pauseOnlyBlocksCreation() public {
        uint256 jobId = _createAccepted(arbiter, 2, _shortDeadline());
        vm.prank(owner);
        escrow.pause();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);
        vm.prank(keeper);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
