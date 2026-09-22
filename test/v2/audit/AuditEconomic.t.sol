// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {PermitToken} from "../mocks/MockModules.sol";
import {BlacklistRevertToken, FeeOnTransferToken} from "./mocks/AuditTokens.sol";
import {AgentAccess} from "../../../src/v2/AgentAccess.sol";
import {AgentReputationV2} from "../../../src/v2/AgentReputationV2.sol";
import {AgentKillSwitchV2} from "../../../src/v2/AgentKillSwitchV2.sol";
import {AgentAuditLogV2} from "../../../src/v2/AgentAuditLogV2.sol";
import {FeeRouter} from "../../../src/v2/FeeRouter.sol";
import {AgentEscrowV2} from "../../../src/v2/AgentEscrowV2.sol";
import {OperatorGated} from "../../../src/v2/OperatorGated.sol";
import {IAgentAccess} from "../../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "../../../src/v2/interfaces/IAgentEscrowV2.sol";
import {IAgentReputationV2} from "../../../src/v2/interfaces/IAgentReputationV2.sol";
import {IAgentKillSwitchV2} from "../../../src/v2/interfaces/IAgentKillSwitchV2.sol";

/// @title AuditEconomicTest
/// @notice Economic / game-theory / token-integration PoCs for the v2 stack, migrated to the fixed
///         contracts. Real modules are wired exactly like script/v2/DeployCore.s.sol. Tests tagged
///         `FIXED: <id>` keep the original exploit scenario and now assert the guarantee the fix
///         provides; tests tagged `DEMONSTRATES: <id>` quantify behaviour that is accepted or
///         documented.
contract AuditEconomicTest is Test {
    ERC20Mock usdc;
    AgentAccess access;
    AgentReputationV2 reputation;
    AgentKillSwitchV2 killSwitch;
    AgentAuditLogV2 auditLog;
    FeeRouter feeRouter;
    AgentEscrowV2 escrow;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address stakingPool = makeAddr("stakingPool");
    address client = makeAddr("client");
    address clientOp = makeAddr("clientOp");
    address provider = makeAddr("provider");
    address providerOp = makeAddr("providerOp");
    address arbiter = makeAddr("arbiter");
    address stranger = makeAddr("stranger");
    address strangerArbiter = makeAddr("strangerArbiter");

    uint256 constant M1 = 100_000_000; // $100
    uint256 constant M2 = 200_000_000; // $200
    uint256 constant TOTAL = M1 + M2;
    uint256 constant MINT = 10_000_000_000; // $10k
    uint256 constant REVIEW = 7 days;
    uint256 constant GRACE = 30 days;
    uint256 constant MAX_REPUTATION_PER_PAIR = 10;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        access = new AgentAccess();
        reputation = new AgentReputationV2(owner);
        killSwitch = new AgentKillSwitchV2(owner);
        auditLog = new AgentAuditLogV2(IAgentAccess(address(access)), owner);
        feeRouter = new FeeRouter(IERC20(address(usdc)), owner, treasury, stakingPool, address(0), 5000, 5000);
        escrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(usdc)), owner);

        vm.startPrank(owner);
        reputation.authorizeProtocol(address(escrow));
        auditLog.authorizeProtocol(address(escrow));
        killSwitch.authorizeProtocol(address(escrow));
        feeRouter.authorizeProtocol(address(escrow));
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
        vm.stopPrank();

        vm.prank(client);
        access.authorizeOperator(clientOp, type(uint48).max);
        vm.prank(provider);
        access.authorizeOperator(providerOp, type(uint48).max);

        usdc.mint(client, MINT);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
        usdc.mint(stranger, MINT);
        vm.prank(stranger);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = a;
        amounts[1] = b;
    }

    function _amountsN(uint256 n, uint256 each) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = each;
        }
    }

    function _params(
        address client_,
        address provider_,
        address arbiter_,
        uint256[] memory amounts,
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
            milestoneAmounts: amounts,
            deadline: deadline,
            termsHash: keccak256("terms")
        });
    }

    function _create(address arbiter_, uint48 deadline) internal returns (uint256 jobId) {
        vm.prank(clientOp);
        jobId = escrow.createJob(_params(client, provider, arbiter_, _amounts(M1, M2), deadline));
    }

    /// @dev A job is only an offer until the provider binds itself with acceptJob.
    function _createAccepted(address arbiter_, uint48 deadline) internal returns (uint256 jobId) {
        jobId = _create(arbiter_, deadline);
        vm.prank(providerOp);
        escrow.acceptJob(jobId);
    }

    function _now48() internal view returns (uint48) {
        return uint48(block.timestamp);
    }

    function _status(uint256 jobId) internal view returns (IAgentEscrowV2.JobStatus) {
        return escrow.getJob(jobId).status;
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-01  settleExpired used to front-run claimApproval; it now vests submitted work
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-01
    /// @dev The fix guarantees a Submitted milestone whose review window closed belongs to the
    ///      provider, so settling first is no longer a way to erase the provider's claim.
    function test_E01_settleExpiredVestsSubmittedMilestoneToProvider() public {
        uint256 jobId = _createAccepted(address(0), _now48() + 1 hours);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done")); // review closes at t+7d

        vm.warp(block.timestamp + REVIEW + 1); // first second both calls are valid

        // Anyone lands first; the rule decides the outcome, not the ordering.
        vm.prank(stranger);
        escrow.settleExpired(jobId);

        vm.prank(providerOp);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Expired)
        );
        escrow.claimApproval(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1, "submitted+unreviewed milestone settled to the provider");
        assertEq(usdc.balanceOf(client), MINT - M1, "client only recovered the unsubmitted milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-02  Provider chained submissions to extend expiry indefinitely
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-02
    /// @dev The fix guarantees submissions stop at the deadline, so expiry is bounded by
    ///      deadline + REVIEW_WINDOW and the client's funds are always recoverable.
    function test_E02_providerCannotChainSubmissionsPastDeadline() public {
        uint48 deadline = _now48() + 1 hours;
        uint256 jobId = _createAccepted(address(0), deadline);

        vm.warp(deadline - 1);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("garbage-1")); // expiry = deadline-1+7d

        // The client reviews inside the window and rejects.
        vm.warp(block.timestamp + 6 days);
        vm.prank(clientOp);
        escrow.rejectMilestone(jobId, 0, keccak256("bad"));

        // The provider can no longer buy a fresh 7-day extension: the deadline has passed.
        vm.warp(block.timestamp + 1);
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.submitMilestone(jobId, 0, keccak256("garbage-2"));

        assertLe(
            uint256(escrow.expiryOf(jobId)),
            uint256(deadline) + REVIEW,
            "expiry never exceeds deadline + one review window"
        );

        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), MINT, "client is out of the job");
        assertEq(uint8(_status(jobId)), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    // FIXED: E-02
    /// @dev The fix guarantees a job past its expiry cannot be resurrected by a late submission.
    function test_E02b_lateSubmissionCannotResurrectAnExpiredJob() public {
        uint48 deadline = _now48() + 1 hours;
        uint256 jobId = _createAccepted(address(0), deadline);

        vm.warp(uint256(deadline) + 100 days); // settleable by anyone right now
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.submitMilestone(jobId, 0, keccak256("late"));
    }

    // FIXED: E-02
    /// @dev The fix guarantees the client no longer needs an atomic reject+settle batch: once the
    ///      deadline has passed the provider cannot slip a submission in between the two calls.
    function test_E02c_clientNoLongerNeedsAnAtomicRejectAndSettle() public {
        uint48 deadline = _now48() + 1 hours;
        uint256 jobId = _createAccepted(address(0), deadline);
        vm.warp(deadline - 1);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("garbage"));
        vm.warp(block.timestamp + 1 days);

        vm.prank(clientOp);
        escrow.rejectMilestone(jobId, 0, keccak256("bad"));

        // A whole day passes between the two calls and the provider still cannot re-arm the clock.
        vm.warp(block.timestamp + 1 days);
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.submitMilestone(jobId, 0, keccak256("garbage-2"));

        escrow.settleExpired(jobId);
        assertEq(uint8(_status(jobId)), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), MINT);
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-03  reject + cancel in one block bypassed the arbiter entirely
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-03
    /// @dev The fix guarantees `everSubmitted` is sticky, so a rejection can never reopen the cancel
    ///      path and strip a provider that already delivered.
    function test_E03_rejectThenCancelIsBlocked() public {
        uint256 jobId = _createAccepted(arbiter, _now48() + 30 days);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("real-work")); // deliverable already handed over off-chain

        vm.startPrank(clientOp);
        escrow.rejectMilestone(jobId, 0, keccak256("pretext"));
        // Blocked: a milestone was submitted, so the client must dispute instead of cancelling.
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        escrow.cancelJob(jobId);
        vm.stopPrank();

        assertTrue(escrow.getJob(jobId).everSubmitted);
        assertEq(uint8(_status(jobId)), uint8(IAgentEscrowV2.JobStatus.Open), "job stays live");
    }

    // FIXED: E-03
    /// @dev The fix guarantees MIGRATION.md's "your only recourse is dispute" is now true: the job
    ///      stays Open after a rejection and the provider can still reach the arbiter.
    function test_E03b_providerKeepsRecourseAfterAReject() public {
        uint256 jobId = _createAccepted(arbiter, _now48() + 30 days);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("real-work"));

        vm.startPrank(clientOp);
        escrow.rejectMilestone(jobId, 0, keccak256("pretext"));
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        escrow.cancelJob(jobId);
        vm.stopPrank();

        vm.prank(providerOp);
        escrow.dispute(jobId, keccak256("stolen"));
        vm.prank(arbiter);
        escrow.resolve(jobId, 10_000);

        assertEq(usdc.balanceOf(provider), TOTAL, "arbiter could still award the delivered work");
        assertEq(usdc.balanceOf(client), MINT - TOTAL);
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-04  Anyone could push any address's reputation to zero for gas
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-04
    /// @dev The fix guarantees an unaccepted offer carries no reputation consequences: a stranger
    ///      cannot dispute or resolve a job the named provider never engaged with.
    function test_E04_strangerCannotGriefProviderReputation() public {
        uint256 before = reputation.getScore(provider);
        assertEq(before, 100);

        vm.startPrank(stranger);
        uint256 jobId =
            escrow.createJob(_params(stranger, provider, strangerArbiter, _amountsN(1, 1), _now48() + 1 hours));
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.dispute(jobId, keccak256("fake"));
        vm.stopPrank();

        // There is nothing for the sham arbiter to resolve either.
        vm.prank(strangerArbiter);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Open)
        );
        escrow.resolve(jobId, 0);

        assertEq(reputation.getScore(provider), before, "provider untouched on a job it never accepted");
        assertEq(reputation.getScore(stranger), 100, "and the griefer gains nothing either");

        // Even if the provider does accept the dust offer, the scoring gate closes the vector: a
        // $0.000001 dispute is below MIN_REPUTATION_VALUE, so resolve writes nothing either way.
        vm.prank(providerOp);
        escrow.acceptJob(jobId);
        vm.prank(stranger);
        escrow.dispute(jobId, keccak256("fake"));
        vm.prank(strangerArbiter);
        escrow.resolve(jobId, 0);

        assertEq(reputation.getStats(provider).negatives, 0, "a dust dispute records no negative");
        assertEq(reputation.getScore(provider), before, "provider score is still untouched");
        assertEq(reputation.getStats(stranger).positives, 0, "and the griefer earns no 'winning client' credit");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-05  Reputation farming: PLATINUM for gas only
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-05
    /// @dev The fix guarantees two bounds on wash trading: settlements below MIN_REPUTATION_VALUE
    ///      score nothing, and a client/provider pair is capped at MAX_REPUTATION_PER_PAIR events.
    function test_E05_selfDealingPairCannotFarmReputation() public {
        address alice = makeAddr("alice"); // both controlled by one party
        address bob = makeAddr("bob");
        usdc.mint(alice, 1_000_000);
        vm.prank(alice);
        usdc.approve(address(escrow), type(uint256).max);

        // 5 jobs x 20 dust milestones: 100 approvals between one pair, all below the minimum.
        for (uint256 j = 0; j < 5; j++) {
            vm.prank(alice);
            uint256 jobId = escrow.createJob(_params(alice, bob, address(0), _amountsN(20, 1), _now48() + 1 hours));
            vm.prank(bob);
            escrow.acceptJob(jobId);
            vm.startPrank(alice);
            for (uint8 i = 0; i < 20; i++) {
                escrow.approveMilestone(jobId, i);
            }
            vm.stopPrank();
        }

        assertEq(reputation.getStats(bob).positives, 0, "dust settlements are below MIN_REPUTATION_VALUE");
        assertEq(reputation.getScore(bob), 100, "no score bought for gas");
        assertEq(uint8(reputation.getTier(bob)), uint8(IAgentReputationV2.Tier.BRONZE));
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 1_000_000, "no USDC was spent");

        // The dust run also did NOT consume the pair budget, so the same pair can still earn on real
        // work: the gate is a filter, not a way to burn an honest counterparty's allowance.
        usdc.mint(alice, 20 * M1);
        vm.prank(alice);
        uint256 big = escrow.createJob(_params(alice, bob, address(0), _amountsN(20, M1), _now48() + 1 hours));
        vm.prank(bob);
        escrow.acceptJob(big);
        vm.startPrank(alice);
        for (uint8 i = 0; i < 20; i++) {
            escrow.approveMilestone(big, i);
        }
        vm.stopPrank();

        console2.log("E-05 bob score after 20 x $100 approvals:", reputation.getScore(bob));
        assertEq(reputation.getStats(bob).positives, MAX_REPUTATION_PER_PAIR, "capped per client/provider pair");
        assertTrue(reputation.getTier(bob) != IAgentReputationV2.Tier.PLATINUM, "no PLATINUM from one pair");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-06  dispute + silent arbiter used to refund submitted work to the client
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-06
    /// @dev The fix guarantees a silent arbiter is not a win condition: after DISPUTE_GRACE the job
    ///      settles by the same rule as any expiry, so submitted work still pays the provider.
    function test_E06_disputeThenSilentArbiterStillPaysSubmittedWork() public {
        uint48 deadline = _now48() + 7 days;
        uint256 jobId = _createAccepted(arbiter, deadline);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done"));

        vm.prank(clientOp);
        escrow.dispute(jobId, keccak256("stall")); // blocks claimApproval
        uint256 disputedAt = escrow.getJob(jobId).disputedAt;

        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(providerOp);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Disputed)
        );
        escrow.claimApproval(jobId, 0);

        vm.warp(disputedAt + GRACE + 1);
        vm.prank(stranger);
        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M1, "submitted milestone still goes to the provider");
        assertEq(usdc.balanceOf(client), MINT - M1, "stalling only returned the unsubmitted milestone");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-07  Client stalling with no arbiter: cost model, now bounded
    // ═══════════════════════════════════════════════════════════════════

    // DEMONSTRATES: E-07 (bounded by MAX_REJECTIONS)
    function test_E07_clientRejectLoopIsCappedAtMaxRejections_noArbiter() public {
        uint48 deadline = _now48() + 365 days;
        uint256 jobId = _createAccepted(address(0), deadline);

        uint256 clientGas;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(providerOp);
            escrow.submitMilestone(jobId, 0, keccak256(abi.encode("work", i)));
            vm.warp(block.timestamp + REVIEW - 1);
            uint256 g0 = gasleft();
            vm.prank(clientOp);
            escrow.rejectMilestone(jobId, 0, keccak256("no"));
            clientGas += g0 - gasleft();
        }
        console2.log("E-07 client gas for 3 rejections:", clientGas);

        // The loop now ends: the provider is not strung along for the life of the deadline.
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TooManyRejections.selector, jobId, uint8(0)));
        escrow.submitMilestone(jobId, 0, keccak256("work-4"));

        // Without an arbiter the provider still has no recourse for the 3 deliverables it made.
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NoArbiter.selector, jobId));
        escrow.dispute(jobId, keccak256("unfair"));

        vm.warp(uint256(deadline) + 1);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), MINT, "client recovers everything");
        assertEq(usdc.balanceOf(provider), 0, "provider recovers nothing after 3 deliverables");
        assertEq(reputation.getScore(client), 100, "client reputation untouched");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-08  Real USDC blacklist semantics (transfer REVERTS)
    // ═══════════════════════════════════════════════════════════════════

    function _blacklistSetup() internal returns (BlacklistRevertToken token, AgentEscrowV2 e) {
        token = new BlacklistRevertToken();
        e = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(e), type(uint256).max);
    }

    // DEMONSTRATES: E-08 (safe)
    function test_E08_blacklistedProvider_parksAsClaimable_andCanRouteItOut() public {
        (BlacklistRevertToken token, AgentEscrowV2 e) = _blacklistSetup();
        vm.prank(clientOp);
        uint256 jobId = e.createJob(_params(client, provider, address(0), _amounts(M1, M2), _now48() + 1 days));
        vm.prank(providerOp);
        e.acceptJob(jobId);
        token.setBlacklisted(provider, true);

        vm.prank(clientOp);
        e.approveMilestone(jobId, 0); // reverting transfer -> claimable, job not blocked
        assertEq(e.claimable(provider), M1);

        // Withdrawing to itself still fails: that is the blacklisted party's problem, not the escrow's.
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(BlacklistRevertToken.Blacklisted.selector, provider));
        e.withdrawClaimable(provider, provider);

        // But the destination is now a parameter, so the funds are never trapped.
        address rescue = makeAddr("providerRescue");
        vm.prank(providerOp);
        e.withdrawClaimable(provider, rescue);
        assertEq(token.balanceOf(rescue), M1);
        assertEq(e.claimable(provider), 0);
    }

    // DEMONSTRATES: E-08 (documented)
    function test_E08b_blacklistedClient_refundParksAsClaimable() public {
        (BlacklistRevertToken token, AgentEscrowV2 e) = _blacklistSetup();
        uint48 deadline = _now48() + 1 hours;
        vm.prank(clientOp);
        uint256 jobId = e.createJob(_params(client, provider, address(0), _amounts(M1, M2), deadline));
        token.setBlacklisted(client, true);

        vm.warp(uint256(deadline) + 1);
        e.settleExpired(jobId); // does not revert; refund parked
        assertEq(e.claimable(client), TOTAL);
        assertEq(uint8(e.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Expired));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BlacklistRevertToken.Blacklisted.selector, client));
        e.withdrawClaimable(client, client);

        address rescue = makeAddr("clientRescue");
        vm.prank(clientOp);
        e.withdrawClaimable(client, rescue);
        assertEq(token.balanceOf(rescue), TOTAL);
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-09  Fee-on-transfer misdeploy used to make the escrow silently insolvent
    // ═══════════════════════════════════════════════════════════════════

    // FIXED: E-09
    /// @dev The fix guarantees the funding pull is measured: a token that delivers less than `total`
    ///      reverts at creation, so `claimable` can never be unbacked by the escrow balance.
    function test_E09_feeOnTransferTokenIsRejectedAtCreation() public {
        FeeOnTransferToken token = new FeeOnTransferToken(100); // 1%
        AgentEscrowV2 e = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(e), type(uint256).max);

        uint256 received = TOTAL - (TOTAL * 100) / 10_000;
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TokenAmountMismatch.selector, TOTAL, received));
        e.createJob(_params(client, provider, address(0), _amounts(M1, M2), _now48() + 1 days));

        assertEq(e.jobCount(), 0, "no job recorded against a short funding pull");
        assertEq(token.balanceOf(address(e)), 0, "nothing escrowed");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-10  Permit griefing: confirmed safe
    // ═══════════════════════════════════════════════════════════════════

    function _permitSig(
        PermitToken token,
        uint256 pk,
        address spender,
        uint256 value,
        uint256 deadline
    )
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address signer = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                spender,
                value,
                token.nonces(signer),
                deadline
            )
        );
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }

    // DEMONSTRATES: E-10 (safe)
    function test_E10_permitFrontRunConsumedNonce_jobStillCreated() public {
        uint256 pk = 0xA11CE;
        address principal = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 e = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(token)), owner);
        token.mint(principal, MINT);
        vm.prank(principal);
        access.authorizeOperator(clientOp, type(uint48).max);

        uint256 pd = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(token, pk, address(e), TOTAL, pd);

        // Attacker replays the permit directly on the token first.
        vm.prank(stranger);
        token.permit(principal, address(e), TOTAL, pd, v, r, s);
        assertEq(token.allowance(principal, address(e)), TOTAL);

        // Hot key's createJobWithPermit: permit reverts (nonce used), catch, allowance path works.
        vm.prank(clientOp);
        uint256 jobId = e.createJobWithPermit(
            _params(principal, provider, address(0), _amounts(M1, M2), _now48() + 1 days), pd, v, r, s
        );
        assertEq(e.getJob(jobId).client, principal);
        assertEq(token.balanceOf(address(e)), TOTAL);
    }

    // DEMONSTRATES: E-10 (safe)
    function test_E10b_attackerCannotUseVictimPermitForOwnJob() public {
        uint256 pk = 0xB0B;
        address victim = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 e = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(token)), owner);
        token.mint(victim, MINT);
        uint256 pd = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(token, pk, address(e), TOTAL, pd);

        // p.client = victim: blocked by access control.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, victim, stranger));
        e.createJobWithPermit(_params(victim, stranger, address(0), _amounts(M1, M2), _now48() + 1 days), pd, v, r, s);

        // p.client = attacker: permit(owner=attacker) fails signature check, attacker has no allowance.
        vm.prank(stranger);
        vm.expectRevert();
        e.createJobWithPermit(_params(stranger, provider, address(0), _amounts(M1, M2), _now48() + 1 days), pd, v, r, s);

        assertEq(token.balanceOf(victim), MINT);
        assertEq(token.nonces(victim), 0, "victim permit not consumed by attacker");
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-11  Kill switch scope: killed agents keep acting on existing jobs
    // ═══════════════════════════════════════════════════════════════════

    // DEMONSTRATES: E-11 (documented)
    function test_E11_killedProviderStillSubmitsAndClaims_killedClientStillApproves() public {
        vm.prank(provider);
        killSwitch.register(1, 0, 1 days);
        vm.prank(client);
        killSwitch.register(uint128(MINT), 0, 1 days);
        uint256 jobId = _createAccepted(address(0), _now48() + 30 days);

        vm.prank(provider);
        killSwitch.kill(provider);
        vm.prank(client);
        killSwitch.kill(client);

        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("d")); // killed provider still acts
        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(providerOp);
        escrow.claimApproval(jobId, 0); // and still gets paid
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 1); // killed client still releases committed funds
        assertEq(usdc.balanceOf(provider), TOTAL);

        // Only NEW job creation is gated.
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, client));
        escrow.createJob(_params(client, stranger, address(0), _amounts(1, 1), _now48() + 1 hours));
    }

    // DEMONSTRATES: E-11 (documented)
    /// @dev A killed provider cannot be bound to NEW work either: acceptJob re-checks isActive.
    function test_E11b_killedProviderCannotAcceptANewOffer() public {
        vm.prank(provider);
        killSwitch.register(uint128(MINT), 0, 1 days);
        uint256 jobId = _create(address(0), _now48() + 30 days);

        vm.prank(provider);
        killSwitch.kill(provider);

        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ProviderInactive.selector, provider));
        escrow.acceptJob(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // E-12  Compromised client operator: blast radius
    // ═══════════════════════════════════════════════════════════════════

    // DEMONSTRATES: E-12
    function test_E12_compromisedOperatorDrainsAllowanceInOneBlock_noKillSwitch() public {
        address attacker = makeAddr("attacker");
        uint256 bal = usdc.balanceOf(client);

        vm.prank(clientOp); // leaked hot key
        uint256 jobId = escrow.createJob(_params(client, attacker, address(0), _amountsN(1, bal), _now48() + 1 hours));
        // The payee is the attacker's own address, so acceptJob costs it nothing.
        vm.prank(attacker);
        escrow.acceptJob(jobId);
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0); // no submission required

        assertEq(usdc.balanceOf(attacker), bal, "entire balance under allowance gone in one block");
        assertEq(usdc.balanceOf(client), 0);
    }

    // DEMONSTRATES: E-12
    function test_E12b_killSwitchCapsPerSession_butSessionsAutoRoll() public {
        address attacker = makeAddr("attacker");
        uint128 limit = 500_000_000; // $500 / 24h as in the skill doc
        vm.prank(client);
        killSwitch.register(limit, 20, 1 days);

        vm.prank(clientOp);
        uint256 j0 = escrow.createJob(_params(client, attacker, address(0), _amountsN(1, limit), _now48() + 1 hours));
        vm.prank(attacker);
        escrow.acceptJob(j0);
        vm.startPrank(clientOp);
        escrow.approveMilestone(j0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, client, uint256(1), uint256(0))
        );
        escrow.createJob(_params(client, attacker, address(0), _amountsN(1, 1), _now48() + 1 hours));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days); // session rolls without any principal action
        vm.prank(clientOp);
        uint256 j1 = escrow.createJob(_params(client, attacker, address(0), _amountsN(1, limit), _now48() + 1 hours));
        vm.prank(attacker);
        escrow.acceptJob(j1);
        vm.prank(clientOp);
        escrow.approveMilestone(j1, 0);

        assertEq(usdc.balanceOf(attacker), uint256(limit) * 2, "limit per session, unbounded over sessions");
        console2.log("E-12 drained per 24h with $500 cap (USDC 6dp):", uint256(limit));
    }
}
