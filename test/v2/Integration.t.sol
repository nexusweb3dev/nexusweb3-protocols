// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {AgentIdentityV2} from "../../src/v2/AgentIdentityV2.sol";
import {AgentReputationV2} from "../../src/v2/AgentReputationV2.sol";
import {AgentKillSwitchV2} from "../../src/v2/AgentKillSwitchV2.sol";
import {AgentAuditLogV2} from "../../src/v2/AgentAuditLogV2.sol";
import {FeeRouter} from "../../src/v2/FeeRouter.sol";
import {AgentEscrowV2} from "../../src/v2/AgentEscrowV2.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "../../src/v2/interfaces/IAgentEscrowV2.sol";
import {IAgentReputationV2} from "../../src/v2/interfaces/IAgentReputationV2.sol";
import {IAgentAuditLogV2} from "../../src/v2/interfaces/IAgentAuditLogV2.sol";
import {IAgentKillSwitchV2} from "../../src/v2/interfaces/IAgentKillSwitchV2.sol";
import {IAgentIdentityV2} from "../../src/v2/interfaces/IAgentIdentityV2.sol";

/// @notice Full-stack lifecycle: the loop that makes the stack sticky. One job flows through
///         Identity -> Access (operators) -> KillSwitch -> Escrow -> Reputation + AuditLog + FeeRouter.
contract IntegrationTest is Test {
    ERC20Mock usdc;
    AgentAccess access;
    AgentIdentityV2 identity;
    AgentReputationV2 reputation;
    AgentKillSwitchV2 killSwitch;
    AgentAuditLogV2 auditLog;
    FeeRouter feeRouter;
    AgentEscrowV2 escrow;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address stakingPool = makeAddr("stakingPool");
    address client = makeAddr("client"); // cold principal, holds USDC
    address clientOp = makeAddr("clientOp"); // hot key
    address provider = makeAddr("provider");
    address providerOp = makeAddr("providerOp");
    address arbiter = makeAddr("arbiter");

    uint256 constant M1 = 400_000_000; // $400
    uint256 constant M2 = 600_000_000; // $600
    uint256 constant TOTAL = M1 + M2;
    uint256 constant FEE_BPS = 100; // 1% (switched on for the test)

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        access = new AgentAccess();
        identity = new AgentIdentityV2(IAgentAccess(address(access)), owner, address(0));
        reputation = new AgentReputationV2(owner);
        killSwitch = new AgentKillSwitchV2(owner);
        auditLog = new AgentAuditLogV2(IAgentAccess(address(access)), owner);
        feeRouter = new FeeRouter(IERC20(address(usdc)), owner, treasury, stakingPool, address(0), 5000, 5000);
        escrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(usdc)), owner);

        // Wiring exactly as script/v2/DeployCore.s.sol does it.
        vm.startPrank(owner);
        reputation.authorizeProtocol(address(escrow));
        auditLog.authorizeProtocol(address(escrow));
        killSwitch.authorizeProtocol(address(escrow));
        feeRouter.authorizeProtocol(address(escrow));
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
        escrow.setFeeBps(FEE_BPS);
        vm.stopPrank();

        // Principals delegate to hot keys and register identities via the hot keys.
        vm.prank(client);
        access.authorizeOperator(clientOp, uint48(block.timestamp + 30 days));
        vm.prank(provider);
        access.authorizeOperator(providerOp, uint48(block.timestamp + 30 days));
        vm.prank(clientOp);
        identity.register(client, "acme-buyer", "ipfs://client", 0);
        vm.prank(providerOp);
        identity.register(provider, "dev-agent", "ipfs://provider", 3);

        // Client sets a per-day spending guard on itself (principal only).
        vm.prank(client);
        killSwitch.register(uint128(2_000_000_000), 10, 1 days);

        usdc.mint(client, 10_000_000_000);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _params() internal view returns (IAgentEscrowV2.CreateParams memory p) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = M1;
        amounts[1] = M2;
        p = IAgentEscrowV2.CreateParams({
            client: client,
            provider: provider,
            arbiter: arbiter,
            milestoneAmounts: amounts,
            deadline: uint48(block.timestamp + 7 days),
            termsHash: keccak256("terms v1")
        });
    }

    function _createAccepted() internal returns (uint256 jobId) {
        vm.prank(clientOp);
        jobId = escrow.createJob(_params());
        vm.prank(providerOp);
        escrow.acceptJob(jobId);
    }

    function test_fullLifecycle_hotKeysOnly() public {
        // Hot key creates the job; USDC leaves the cold principal; provider hot key accepts.
        uint256 jobId = _createAccepted();
        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - TOTAL);

        // Kill switch consumed the spend for the principal.
        IAgentKillSwitchV2.AgentConfig memory cfg = killSwitch.getConfig(client);
        assertEq(cfg.spent, TOTAL);
        assertEq(cfg.txCount, 1);

        // Provider hot key delivers, client hot key approves both milestones.
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable-1"));
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 1, keccak256("deliverable-2"));
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 1);

        // Money: provider paid net of fee, fee split to staking + treasury, escrow empty.
        uint256 fee = TOTAL * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), TOTAL - fee);
        assertEq(usdc.balanceOf(stakingPool) + usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Completed));

        // Reputation accrued for BOTH principals (not the hot keys).
        IAgentReputationV2.Stats memory ps = reputation.getStats(provider);
        assertEq(ps.positives, 2);
        assertEq(ps.volumeUsdc, TOTAL);
        assertEq(reputation.getScore(provider), 100 + 2 * 10 + TOTAL / 100e6);
        IAgentReputationV2.Stats memory cs = reputation.getStats(client);
        assertEq(cs.positives, 1);
        assertEq(reputation.getScore(clientOp), 100); // hot key has no reputation

        // Audit trail exists for both principals, written by the escrow (an authorized protocol).
        assertGt(auditLog.getLogCount(provider), 0);
        IAgentAuditLogV2.ActionLog[] memory logs = auditLog.getAgentLogs(client, 0, 100);
        assertEq(logs[0].actionType, bytes32("ESCROW_JOB_CREATED"));
        assertEq(logs[1].actionType, bytes32("ESCROW_JOB_ACCEPTED"));
        assertEq(logs[0].caller, address(escrow));
        assertEq(logs[logs.length - 1].actionType, bytes32("ESCROW_JOB_COMPLETED"));
    }

    function test_killSwitch_blocksJobOverLimit() public {
        IAgentEscrowV2.CreateParams memory p = _params();
        p.milestoneAmounts[1] = 2_000_000_000; // total $2,400 > $2,000 session limit
        vm.prank(clientOp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentKillSwitchV2.SpendingLimitExceeded.selector, client, 2_400_000_000, 2_000_000_000
            )
        );
        escrow.createJob(p);
    }

    function test_killSwitch_guardianKillsClient_noNewJobs() public {
        address guardian = makeAddr("guardian");
        vm.prank(client);
        killSwitch.setGuardian(guardian);
        vm.prank(guardian);
        killSwitch.kill(client);

        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, client));
        escrow.createJob(_params());

        // Only the principal can resume.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, guardian));
        killSwitch.resume();
        vm.prank(client);
        killSwitch.resume();
        vm.prank(clientOp);
        escrow.createJob(_params());
    }

    function test_killedProvider_cannotBeHired() public {
        vm.prank(provider);
        killSwitch.register(uint128(1), 0, 1 days);
        vm.prank(provider);
        killSwitch.kill(provider);
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ProviderInactive.selector, provider));
        escrow.createJob(_params());
    }

    function test_dispute_arbiterSplits_reputationFollows() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("bad-work"));
        vm.prank(clientOp);
        escrow.dispute(jobId, keccak256("not as specified"));

        vm.prank(arbiter);
        escrow.resolve(jobId, 2500); // provider gets 25%

        uint256 toProvider = TOTAL * 2500 / 10_000;
        uint256 fee = toProvider * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), toProvider - fee);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - toProvider);
        assertEq(reputation.getStats(provider).negatives, 1);
        assertEq(reputation.getStats(client).positives, 1);
    }

    function test_revokedOperator_losesAccessEverywhere() public {
        vm.prank(client);
        access.revokeOperator(clientOp);
        vm.prank(clientOp);
        vm.expectRevert();
        escrow.createJob(_params());
        vm.prank(clientOp);
        vm.expectRevert();
        identity.setAgentURI(client, "ipfs://new");
        vm.prank(clientOp);
        vm.expectRevert();
        auditLog.log(client, "X", keccak256("x"), 0);
        // Principal itself still works.
        vm.prank(client);
        identity.setAgentURI(client, "ipfs://new");
    }

    function test_expiredJob_refundsClient_noReputationChange() public {
        vm.prank(clientOp);
        uint256 jobId = escrow.createJob(_params());
        vm.warp(block.timestamp + 8 days);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), 10_000_000_000);
        assertEq(reputation.getStats(provider).negatives, 0);
        assertEq(reputation.getStats(provider).positives, 0);
    }

    function test_moduleOutage_neverLocksFunds() public {
        uint256 jobId = _createAccepted();
        // Owner pauses reputation and audit log (writes revert); escrow keeps paying out.
        vm.startPrank(owner);
        reputation.pause();
        auditLog.pause();
        vm.stopPrank();
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(reputation.getStats(provider).positives, 0);
    }

    function test_feeSwitchOff_zeroFees() public {
        vm.prank(owner);
        escrow.setFeeBps(0);
        uint256 jobId = _createAccepted();
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
        assertEq(usdc.balanceOf(provider), M1);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(stakingPool), 0);
    }

    function test_dispute_afterDeadline_rejected_noLockupExtension() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("late"));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.dispute(jobId, keccak256("stall"));
        // Settlement by rule, immediately: the submitted milestone vests to the provider,
        // the unsubmitted one refunds to the client.
        escrow.settleExpired(jobId);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - M1);
    }

    function test_reviewWindow_silentClient_providerClaims() public {
        uint256 jobId = _createAccepted(); // deadline = day 7
        vm.warp(block.timestamp + 5 days);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done")); // review window ends day 12

        // Too early: window still open.
        vm.prank(providerOp);
        vm.expectRevert();
        escrow.claimApproval(jobId, 0);

        // Deadline (day 7) passes, but the submission is still under review, so no refund yet.
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
        assertEq(escrow.expiryOf(jobId), uint48(block.timestamp - 2 days - 1 + 7 days));

        // Window elapses (day 12): provider gets paid for the ignored milestone.
        vm.warp(block.timestamp + 5 days);
        vm.prank(providerOp);
        escrow.claimApproval(jobId, 0);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(reputation.getStats(provider).positives, 1);

        // Nothing else submitted: the rest expires back to the client.
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - M1);
    }

    function test_reviewWindow_clientRejectsInTime_blocksClaim() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("junk"));
        vm.warp(block.timestamp + 6 days);
        vm.prank(clientOp);
        escrow.rejectMilestone(jobId, 0, keccak256("not acceptable"));
        vm.warp(block.timestamp + 2 days);
        vm.prank(providerOp);
        vm.expectRevert();
        escrow.claimApproval(jobId, 0); // back to Pending, nothing to claim
        escrow.settleExpired(jobId); // deadline passed, no live submission
        assertEq(usdc.balanceOf(client), 10_000_000_000);
    }

    function test_feeRouterFault_parksFeeForOwner_payoutProceeds() public {
        uint256 jobId = _createAccepted();
        vm.prank(owner);
        feeRouter.revokeProtocol(address(escrow)); // simulate a misconfigured router
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(escrow.claimable(owner), fee);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
        vm.prank(owner);
        escrow.withdrawClaimable(owner, owner);
        assertEq(usdc.balanceOf(owner), fee);
        assertEq(usdc.balanceOf(address(escrow)), M2);
    }

    /// @dev For every gas limit, the call either reverts or the best-effort hooks actually landed.
    ///      This is what stops eth_estimateGas from picking a limit that silently drops the writes.
    function test_gasFloor_noLimitDropsHooksSilently() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("d"));
        uint256 logsBefore = auditLog.getLogCount(provider);
        uint256 posBefore = reputation.getStats(provider).positives;

        bytes memory data = abi.encodeCall(escrow.approveMilestone, (jobId, 0));
        for (uint256 g = 60_000; g <= 1_400_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(clientOp);
            (bool ok,) = address(escrow).call{gas: g}(data);
            if (ok) {
                assertEq(auditLog.getLogCount(provider), logsBefore + 1, "log dropped");
                assertEq(reputation.getStats(provider).positives, posBefore + 1, "reputation dropped");
                assertEq(
                    usdc.balanceOf(address(feeRouter)) + usdc.balanceOf(treasury) + usdc.balanceOf(stakingPool),
                    M1 * FEE_BPS / 10_000,
                    "fee dropped"
                );
            }
            vm.revertToState(snap);
        }
    }

    function test_offer_notAccepted_clientCancelsAnytime_noReputation() public {
        vm.prank(clientOp);
        uint256 jobId = escrow.createJob(_params());
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.submitMilestone(jobId, 0, keccak256("x"));
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        escrow.dispute(jobId, keccak256("x"));
        vm.prank(clientOp);
        escrow.cancelJob(jobId);
        assertEq(usdc.balanceOf(client), 10_000_000_000);
        assertEq(reputation.getStats(provider).positives + reputation.getStats(provider).negatives, 0);
    }

    function test_vesting_settleCannotFrontRunClaim() public {
        uint256 jobId = _createAccepted();
        vm.warp(block.timestamp + 5 days);
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done"));
        vm.warp(block.timestamp + 7 days + 1); // window closed, expiry reached at the same second
        // Whoever settles, the submitted milestone is the provider's.
        escrow.settleExpired(jobId);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - M1);
    }

    function test_rejectAfterWindow_blocked() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done"));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ReviewWindowClosed.selector, jobId, 0));
        escrow.rejectMilestone(jobId, 0, keccak256("late"));
    }

    function test_submitAfterDeadline_blocked_and_rejectionCap() public {
        uint256 jobId = _createAccepted();
        for (uint8 i = 0; i < 3; i++) {
            vm.prank(providerOp);
            escrow.submitMilestone(jobId, 0, keccak256(abi.encode(i)));
            vm.prank(clientOp);
            escrow.rejectMilestone(jobId, 0, keccak256("no"));
        }
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TooManyRejections.selector, jobId, 0));
        escrow.submitMilestone(jobId, 0, keccak256("again"));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(providerOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        escrow.submitMilestone(jobId, 1, keccak256("late"));
        // Client cannot cancel after submissions; deadline settlement refunds the client.
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        escrow.cancelJob(jobId);
        escrow.settleExpired(jobId);
        assertEq(usdc.balanceOf(client), 10_000_000_000);
    }

    function test_dispute_silentArbiter_submittedWorkPaysProvider() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("done"));
        vm.prank(clientOp);
        escrow.dispute(jobId, keccak256("stall"));
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
        vm.warp(block.timestamp + 30 days + 1);
        escrow.settleExpired(jobId);
        uint256 fee = M1 * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(usdc.balanceOf(client), 10_000_000_000 - M1);
    }

    function test_arbiterMustBeIndependent() public {
        IAgentEscrowV2.CreateParams memory p = _params();
        p.arbiter = clientOp; // client's own operator
        vm.prank(clientOp);
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        escrow.createJob(p);
    }

    function test_blacklistedRecipient_operatorWithdrawsClaimableElsewhere() public {
        // Simulate: provider gets parked funds (pause-free path: use a token that blocks provider)
        // Covered in unit suite with FailingToken; here check the operator/to path on parked owner fee.
        uint256 jobId = _createAccepted();
        vm.prank(owner);
        feeRouter.revokeProtocol(address(escrow));
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
        uint256 fee = M1 * FEE_BPS / 10_000;
        address ownerOp = makeAddr("ownerOp");
        vm.prank(owner);
        access.authorizeOperator(ownerOp, uint48(block.timestamp + 1 days));
        vm.prank(ownerOp);
        escrow.withdrawClaimable(owner, treasury);
        assertEq(usdc.balanceOf(treasury), fee);
    }

    function test_operatorCanRenounceItself() public {
        vm.prank(clientOp);
        access.renounceOperator(client);
        assertFalse(access.isOperatorFor(client, clientOp));
        vm.prank(clientOp);
        vm.expectRevert();
        escrow.createJob(_params());
        // A stranger cannot renounce a key it does not hold.
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, client, makeAddr("nobody")));
        access.renounceOperator(client);
    }

    function test_dustJob_earnsNoPositiveReputation() public {
        IAgentEscrowV2.CreateParams memory p = _params();
        p.milestoneAmounts[0] = 1; // 0.000001 USDC
        p.milestoneAmounts[1] = 9_999_998; // total just under $10
        vm.prank(clientOp);
        uint256 jobId = escrow.createJob(p);
        vm.prank(providerOp);
        escrow.acceptJob(jobId);
        vm.startPrank(clientOp);
        escrow.approveMilestone(jobId, 0);
        escrow.approveMilestone(jobId, 1);
        vm.stopPrank();
        assertEq(reputation.getStats(provider).positives, 0);
        assertEq(reputation.getStats(client).positives, 0); // job total < $10 too
        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Completed));
    }

    function test_revert_escrowConstructor_tokenWithoutCode() public {
        vm.expectRevert(IAgentEscrowV2.ZeroAddress.selector);
        new AgentEscrowV2(IAgentAccess(address(access)), IERC20(makeAddr("eoa-token")), owner);
    }

    function test_rename_releasesOldName_viaOperator() public {
        vm.prank(clientOp);
        identity.rename(client, "acme-buyer-2");
        assertEq(identity.getAgentByName("acme-buyer"), address(0));
        assertEq(identity.getAgentByName("acme-buyer-2"), client);
        // Old name is free for someone else now.
        address other = makeAddr("other");
        vm.prank(other);
        identity.register(other, "acme-buyer", "", 0);
        // Cannot take a name in use, cannot use a bad charset.
        vm.prank(clientOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NameTaken.selector, keccak256(abi.encode("dev-agent"))));
        identity.rename(client, "dev-agent");
        vm.prank(clientOp);
        vm.expectRevert(IAgentIdentityV2.InvalidName.selector);
        identity.rename(client, "Acme Buyer");
    }

    function test_operatorExpiry_readsZeroOnceLapsed_arbiterCheckUsesLiveOnly() public {
        address exOp = makeAddr("exOp");
        vm.prank(client);
        access.authorizeOperator(exOp, uint48(block.timestamp + 1 hours));
        assertGt(access.operatorExpiry(client, exOp), 0);
        vm.warp(block.timestamp + 2 hours);
        assertEq(access.operatorExpiry(client, exOp), 0);
        assertFalse(access.isOperatorFor(client, exOp));
        // A lapsed former operator is an acceptable arbiter again.
        IAgentEscrowV2.CreateParams memory p = _params();
        p.arbiter = exOp;
        vm.prank(clientOp);
        escrow.createJob(p);
    }

    function test_payoutSettled_deliveredAndParked() public {
        uint256 jobId = _createAccepted();
        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 0, keccak256("d"));
        uint256 fee = M1 * FEE_BPS / 10_000;
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IAgentEscrowV2.PayoutSettled(jobId, provider, M1 - fee, true);
        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 0);
    }
}
