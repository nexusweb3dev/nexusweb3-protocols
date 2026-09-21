// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {
    FailingToken,
    MockAuditLog,
    MockFeeRouter,
    MockKillSwitch,
    MockReputation,
    PermitToken
} from "./mocks/MockModules.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {AgentEscrowV2} from "../../src/v2/AgentEscrowV2.sol";
import {OperatorGated} from "../../src/v2/OperatorGated.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "../../src/v2/interfaces/IAgentEscrowV2.sol";

contract AgentEscrowV2Test is Test {
    ERC20Mock usdc;
    AgentAccess accessControl;
    AgentEscrowV2 escrow;

    MockReputation reputation;
    MockAuditLog auditLog;
    MockKillSwitch killSwitch;
    MockFeeRouter feeRouter;

    address owner = makeAddr("owner");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address arbiter = makeAddr("arbiter");
    address clientOp = makeAddr("clientOp");
    address providerOp = makeAddr("providerOp");
    address arbiterOp = makeAddr("arbiterOp");
    address stranger = makeAddr("stranger");

    uint256 constant BPS = 10_000;
    uint256 constant M1 = 100_000_000; // $100
    uint256 constant M2 = 200_000_000; // $200
    uint256 constant M3 = 700_000_000; // $700
    uint256 constant TOTAL = 1_000_000_000; // $1000
    uint256 constant MINT = 1_000_000_000_000; // $1M
    uint48 constant THIRTY_DAYS = 30 days;
    uint8 constant CATEGORY_ESCROW = 1;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        accessControl = new AgentAccess();
        escrow = new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(usdc)), owner);

        reputation = new MockReputation();
        auditLog = new MockAuditLog();
        killSwitch = new MockKillSwitch();
        feeRouter = new MockFeeRouter();

        vm.prank(client);
        accessControl.authorizeOperator(clientOp, type(uint48).max);
        vm.prank(provider);
        accessControl.authorizeOperator(providerOp, type(uint48).max);
        vm.prank(arbiter);
        accessControl.authorizeOperator(arbiterOp, type(uint48).max);

        usdc.mint(client, MINT);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _deadline() internal view returns (uint48) {
        return uint48(block.timestamp) + THIRTY_DAYS;
    }

    function _amounts3() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = M1;
        amounts[1] = M2;
        amounts[2] = M3;
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
        uint256[] memory amounts
    )
        internal
        view
        returns (IAgentEscrowV2.CreateParams memory)
    {
        return IAgentEscrowV2.CreateParams({
            client: client_,
            provider: provider_,
            arbiter: arbiter_,
            milestoneAmounts: amounts,
            deadline: _deadline(),
            termsHash: keccak256("terms")
        });
    }

    function _defaultParams() internal view returns (IAgentEscrowV2.CreateParams memory) {
        return _params(client, provider, arbiter, _amounts3());
    }

    function _createDefault() internal returns (uint256 jobId) {
        vm.prank(client);
        return escrow.createJob(_defaultParams());
    }

    function _createNoArbiter() internal returns (uint256 jobId) {
        vm.prank(client);
        return escrow.createJob(_params(client, provider, address(0), _amounts3()));
    }

    function _wireModules() internal {
        vm.prank(owner);
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
    }

    function _setFee(uint256 bps) internal {
        _wireModules();
        vm.prank(owner);
        escrow.setFeeBps(bps);
    }

    function _approveAll(uint256 jobId, uint8 count) internal {
        for (uint8 i = 0; i < count; i++) {
            vm.prank(client);
            escrow.approveMilestone(jobId, i);
        }
    }

    function _lockedInJobs(uint256 nJobs) internal view returns (uint256 locked) {
        for (uint256 i = 0; i < nJobs; i++) {
            IAgentEscrowV2.Job memory job = escrow.getJob(i);
            locked += job.total - job.released - job.refunded;
        }
    }

    function _assertBalanceInvariant(uint256 nJobs) internal view {
        uint256 expected = _lockedInJobs(nJobs) + escrow.claimable(client) + escrow.claimable(provider)
            + escrow.claimable(arbiter) + escrow.claimable(stranger);
        assertEq(usdc.balanceOf(address(escrow)), expected, "escrow balance != locked + claimable");
    }

    // ─── Constructor & fresh views ──────────────────────────────────────

    function test_constructor() public view {
        assertEq(escrow.paymentToken(), address(usdc));
        assertEq(escrow.owner(), owner);
        assertEq(address(escrow.access()), address(accessControl));
        assertEq(escrow.feeBps(), 0);
        assertEq(escrow.jobCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentEscrowV2.ZeroAddress.selector);
        new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(0)), owner);
    }

    function test_revert_constructorZeroAccess() public {
        vm.expectRevert(OperatorGated.ZeroAccess.selector);
        new AgentEscrowV2(IAgentAccess(address(0)), IERC20(address(usdc)), owner);
    }

    function test_freshViews() public view {
        assertEq(escrow.reputation(), address(0));
        assertEq(escrow.auditLog(), address(0));
        assertEq(escrow.killSwitch(), address(0));
        assertEq(escrow.feeRouter(), address(0));
        assertEq(escrow.claimable(client), 0);
        assertEq(escrow.jobCountOf(client), 0);
        assertEq(escrow.getJobsOf(client, 0, 10).length, 0);
        assertFalse(escrow.paused());
    }

    function test_constants() public view {
        assertEq(escrow.MAX_FEE_BPS(), 500);
        assertEq(escrow.BPS(), BPS);
        assertEq(escrow.MAX_MILESTONES(), 20);
        assertEq(escrow.MIN_DURATION(), 1 hours);
        assertEq(escrow.MAX_DURATION(), 365 days);
        assertEq(escrow.DISPUTE_GRACE(), 30 days);
    }

    // ─── createJob ──────────────────────────────────────────────────────

    function test_createJob() public {
        uint256 before = usdc.balanceOf(client);
        uint256 jobId = _createDefault();

        assertEq(jobId, 0);
        assertEq(escrow.jobCount(), 1);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.arbiter, arbiter);
        assertEq(job.total, TOTAL);
        assertEq(job.released, 0);
        assertEq(job.refunded, 0);
        assertEq(job.deadline, _deadline());
        assertEq(job.createdAt, uint48(block.timestamp));
        assertEq(job.milestoneCount, 3);
        assertEq(job.approvedCount, 0);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Open));
        assertEq(job.termsHash, keccak256("terms"));

        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
        assertEq(usdc.balanceOf(client), before - TOTAL);
    }

    function test_createJob_storesMilestonesPending() public {
        uint256 jobId = _createDefault();
        IAgentEscrowV2.Milestone[] memory ms = escrow.getMilestones(jobId);

        assertEq(ms.length, 3);
        assertEq(ms[0].amount, M1);
        assertEq(ms[1].amount, M2);
        assertEq(ms[2].amount, M3);
        for (uint256 i = 0; i < ms.length; i++) {
            assertEq(uint8(ms[i].status), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
            assertEq(ms[i].deliverableHash, bytes32(0));
            assertEq(ms[i].submittedAt, 0);
        }
    }

    function test_createJob_indexesBothParties() public {
        uint256 jobId = _createDefault();

        assertEq(escrow.jobCountOf(client), 1);
        assertEq(escrow.jobCountOf(provider), 1);
        assertEq(escrow.jobCountOf(arbiter), 0);
        assertEq(escrow.getJobsOf(client, 0, 10)[0], jobId);
        assertEq(escrow.getJobsOf(provider, 0, 10)[0], jobId);
    }

    function test_createJob_emitsJobCreated() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobCreated(0, client, provider, arbiter, TOTAL, _deadline());
        vm.prank(client);
        escrow.createJob(_defaultParams());
    }

    function test_createJob_viaOperator() public {
        vm.prank(clientOp);
        uint256 jobId = escrow.createJob(_defaultParams());

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.client, client);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
    }

    function test_createJob_incrementsIds() public {
        assertEq(_createDefault(), 0);
        assertEq(_createDefault(), 1);
        assertEq(_createDefault(), 2);
        assertEq(escrow.jobCount(), 3);
        assertEq(escrow.jobCountOf(client), 3);
    }

    function test_createJob_noArbiterAllowed() public {
        uint256 jobId = _createNoArbiter();
        assertEq(escrow.getJob(jobId).arbiter, address(0));
    }

    function test_createJob_maxMilestones() public {
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(20, M1)));

        assertEq(escrow.getJob(jobId).milestoneCount, 20);
        assertEq(escrow.getJob(jobId).total, M1 * 20);
    }

    function test_createJob_deadlineBoundaries() public {
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = uint48(block.timestamp + 1 hours);
        vm.prank(client);
        escrow.createJob(p);

        p.deadline = uint48(block.timestamp + 365 days);
        vm.prank(client);
        escrow.createJob(p);

        assertEq(escrow.jobCount(), 2);
    }

    function test_revert_createJob_notAgentOrOperator() public {
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, client, stranger));
        vm.prank(stranger);
        escrow.createJob(_defaultParams());
    }

    function test_revert_createJob_zeroProvider() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, address(0), arbiter, _amounts3()));
    }

    function test_revert_createJob_providerIsClient() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, client, arbiter, _amounts3()));
    }

    function test_revert_createJob_arbiterIsClient() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, client, _amounts3()));
    }

    function test_revert_createJob_arbiterIsProvider() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, provider, _amounts3()));
    }

    function test_revert_createJob_zeroMilestones() public {
        vm.expectRevert(IAgentEscrowV2.InvalidMilestones.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, arbiter, new uint256[](0)));
    }

    function test_revert_createJob_tooManyMilestones() public {
        vm.expectRevert(IAgentEscrowV2.InvalidMilestones.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, arbiter, _amountsN(21, M1)));
    }

    function test_revert_createJob_zeroAmountMilestone() public {
        uint256[] memory amounts = _amounts3();
        amounts[1] = 0;

        vm.expectRevert(IAgentEscrowV2.InvalidMilestones.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, arbiter, amounts));
    }

    function test_revert_createJob_deadlineTooSoon() public {
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = uint48(block.timestamp + 1 hours - 1);

        vm.expectRevert(IAgentEscrowV2.InvalidDeadline.selector);
        vm.prank(client);
        escrow.createJob(p);
    }

    function test_revert_createJob_deadlineTooFar() public {
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = uint48(block.timestamp + 365 days + 1);

        vm.expectRevert(IAgentEscrowV2.InvalidDeadline.selector);
        vm.prank(client);
        escrow.createJob(p);
    }

    function test_revert_createJob_whenPaused() public {
        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(client);
        escrow.createJob(_defaultParams());
    }

    function test_createJob_afterUnpause() public {
        vm.prank(owner);
        escrow.pause();
        vm.prank(owner);
        escrow.unpause();

        assertEq(_createDefault(), 0);
    }

    function test_revert_createJob_insufficientAllowance() public {
        address poorClient = makeAddr("poorClient");
        usdc.mint(poorClient, MINT);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, TOTAL)
        );
        vm.prank(poorClient);
        escrow.createJob(_params(poorClient, provider, arbiter, _amounts3()));
    }

    function test_revert_createJob_insufficientBalance() public {
        address brokeClient = makeAddr("brokeClient");
        vm.prank(brokeClient);
        usdc.approve(address(escrow), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, brokeClient, 0, TOTAL));
        vm.prank(brokeClient);
        escrow.createJob(_params(brokeClient, provider, arbiter, _amounts3()));
    }

    // ─── createJobWithPermit ────────────────────────────────────────────

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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_createJobWithPermit() public {
        uint256 pk = 0xA11CE;
        address permitClient = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 permitEscrow =
            new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(permitClient, MINT);

        uint256 permitDeadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(token, pk, address(permitEscrow), TOTAL, permitDeadline);

        vm.prank(permitClient);
        uint256 jobId = permitEscrow.createJobWithPermit(
            _params(permitClient, provider, arbiter, _amounts3()), permitDeadline, v, r, s
        );

        assertEq(permitEscrow.getJob(jobId).total, TOTAL);
        assertEq(token.balanceOf(address(permitEscrow)), TOTAL);
        assertEq(token.allowance(permitClient, address(permitEscrow)), 0);
    }

    function test_createJobWithPermit_invalidPermitButAllowanceExists() public {
        uint256 pk = 0xB0B;
        address permitClient = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 permitEscrow =
            new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(permitClient, MINT);

        vm.prank(permitClient);
        token.approve(address(permitEscrow), type(uint256).max);

        // Garbage signature: permit reverts, the try/catch swallows it, the standing allowance is used.
        vm.prank(permitClient);
        uint256 jobId = permitEscrow.createJobWithPermit(
            _params(permitClient, provider, arbiter, _amounts3()), block.timestamp + 1 days, 27, bytes32(0), bytes32(0)
        );

        assertEq(permitEscrow.getJob(jobId).total, TOTAL);
        assertEq(token.balanceOf(address(permitEscrow)), TOTAL);
    }

    function test_revert_createJobWithPermit_invalidPermitNoAllowance() public {
        uint256 pk = 0xCAFE;
        address permitClient = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 permitEscrow =
            new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(permitClient, MINT);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(permitEscrow), 0, TOTAL)
        );
        vm.prank(permitClient);
        permitEscrow.createJobWithPermit(
            _params(permitClient, provider, arbiter, _amounts3()), block.timestamp + 1 days, 27, bytes32(0), bytes32(0)
        );
    }

    function test_revert_createJobWithPermit_whenPaused() public {
        uint256 pk = 0xD00D;
        address permitClient = vm.addr(pk);
        PermitToken token = new PermitToken();
        AgentEscrowV2 permitEscrow =
            new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(permitClient, MINT);

        uint256 permitDeadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(token, pk, address(permitEscrow), TOTAL, permitDeadline);

        vm.prank(owner);
        permitEscrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(permitClient);
        permitEscrow.createJobWithPermit(_params(permitClient, provider, arbiter, _amounts3()), permitDeadline, v, r, s);
    }

    // ─── submitMilestone ────────────────────────────────────────────────

    function test_submitMilestone() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneSubmitted(jobId, 0, keccak256("deliverable"));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable"));

        IAgentEscrowV2.Milestone[] memory ms = escrow.getMilestones(jobId);
        assertEq(uint8(ms[0].status), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
        assertEq(ms[0].deliverableHash, keccak256("deliverable"));
        assertEq(ms[0].submittedAt, uint48(block.timestamp));
    }

    function test_submitMilestone_viaOperator() public {
        uint256 jobId = _createDefault();

        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 1, keccak256("d1"));

        assertEq(uint8(escrow.getMilestones(jobId)[1].status), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
    }

    function test_revert_submit_byClient() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(client);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_byStranger() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(stranger);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_milestoneNotFound() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.MilestoneNotFound.selector, jobId, 3));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 3, bytes32(0));
    }

    function test_revert_submit_alreadySubmitted() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Submitted
            )
        );
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_approved() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Approved
            )
        );
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_jobNotOpen() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.cancelJob(jobId);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Cancelled)
        );
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    // ─── approveMilestone ───────────────────────────────────────────────

    function test_approve_withoutSubmit() public {
        uint256 jobId = _createDefault();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1);
        assertEq(job.approvedCount, 1);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Open));
        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_afterSubmit() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d"));

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(uint8(escrow.getMilestones(jobId)[0].status), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(usdc.balanceOf(provider), M1);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL - M1);
    }

    function test_approve_viaOperator() public {
        uint256 jobId = _createDefault();

        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 1);

        assertEq(usdc.balanceOf(provider), M2);
    }

    function test_approve_emitsEvent() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneApproved(jobId, 2, M3, 0);
        vm.prank(client);
        escrow.approveMilestone(jobId, 2);
    }

    function test_approve_noFeeWhenFeeBpsZero() public {
        _wireModules();
        uint256 jobId = _createDefault();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(escrow.feeBps(), 0);
        assertEq(feeRouter.routeCount(), 0);
        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_withFee() public {
        _setFee(250);
        uint256 jobId = _createDefault();
        uint256 fee = (M1 * 250) / BPS;

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneApproved(jobId, 0, M1 - fee, fee);
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(usdc.balanceOf(address(feeRouter)), fee);
        assertEq(feeRouter.routeCount(), 1);
        assertEq(feeRouter.lastAgent(), provider);
        assertEq(feeRouter.lastAmount(), fee);
        assertEq(escrow.getJob(jobId).released, M1);
    }

    function test_approve_lastCompletesJob() public {
        uint256 jobId = _createDefault();
        _approveAll(jobId, 2);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobCompleted(jobId);
        vm.prank(client);
        escrow.approveMilestone(jobId, 2);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Completed));
        assertEq(job.released, TOTAL);
        assertEq(job.approvedCount, 3);
        assertEq(usdc.balanceOf(provider), TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_approve_completionReputation() public {
        _wireModules();
        uint256 jobId = _createDefault();
        _approveAll(jobId, 3);

        assertEq(reputation.positives(provider), 3);
        assertEq(reputation.positives(client), 1);
        assertEq(reputation.lastValueOf(client), TOTAL);
        assertEq(reputation.lastCategory(), CATEGORY_ESCROW);
        assertTrue(reputation.lastPositiveOf(provider));
    }

    function test_approve_reputationPerMilestone() public {
        _wireModules();
        uint256 jobId = _createDefault();

        vm.prank(client);
        escrow.approveMilestone(jobId, 1);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.lastValueOf(provider), M2);
        assertEq(reputation.positives(client), 0);
    }

    function test_revert_approve_alreadyApproved() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Approved
            )
        );
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
    }

    function test_revert_approve_notClient() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(provider);
        escrow.approveMilestone(jobId, 0);
    }

    function test_revert_approve_milestoneNotFound() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.MilestoneNotFound.selector, jobId, 9));
        vm.prank(client);
        escrow.approveMilestone(jobId, 9);
    }

    function test_revert_approve_jobNotOpen() public {
        uint256 jobId = _createDefault();
        _approveAll(jobId, 3);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Completed)
        );
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
    }

    function test_revert_approve_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 0));
        vm.prank(client);
        escrow.approveMilestone(0, 0);
    }

    function test_approve_worksWhilePaused() public {
        uint256 jobId = _createDefault();
        vm.prank(owner);
        escrow.pause();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    // ─── rejectMilestone ────────────────────────────────────────────────

    function test_reject_submittedBackToPending() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d"));

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneRejected(jobId, 0, keccak256("bad"));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, keccak256("bad"));

        IAgentEscrowV2.Milestone memory m = escrow.getMilestones(jobId)[0];
        assertEq(uint8(m.status), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
        assertEq(m.submittedAt, 0);
        assertEq(m.deliverableHash, keccak256("d"));
    }

    function test_reject_thenResubmit() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d"));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, keccak256("bad"));

        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d2"));

        assertEq(escrow.getMilestones(jobId)[0].deliverableHash, keccak256("d2"));
    }

    function test_reject_viaOperator() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d"));

        vm.prank(clientOp);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertEq(uint8(escrow.getMilestones(jobId)[0].status), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
    }

    function test_revert_reject_pendingMilestone() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Pending
            )
        );
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_reject_notClient() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(provider);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    // ─── cancelJob ──────────────────────────────────────────────────────

    function test_cancel_fullRefund() public {
        uint256 jobId = _createDefault();
        uint256 before = usdc.balanceOf(client);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobCancelled(jobId, TOTAL);
        vm.prank(client);
        escrow.cancelJob(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Cancelled));
        assertEq(job.refunded, TOTAL);
        assertEq(usdc.balanceOf(client), before + TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_cancel_viaOperator() public {
        uint256 jobId = _createDefault();

        vm.prank(clientOp);
        escrow.cancelJob(jobId);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Cancelled));
    }

    function test_cancel_afterRejectedSubmission() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        vm.prank(client);
        escrow.cancelJob(jobId);

        assertEq(escrow.getJob(jobId).refunded, TOTAL);
    }

    function test_revert_cancel_afterSubmit() public {
        uint256 jobId = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        vm.prank(client);
        escrow.cancelJob(jobId);
    }

    function test_revert_cancel_afterApproval() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        vm.prank(client);
        escrow.cancelJob(jobId);
    }

    function test_revert_cancel_notClient() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(stranger);
        escrow.cancelJob(jobId);
    }

    function test_revert_cancel_notOpen() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.cancelJob(jobId);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Cancelled)
        );
        vm.prank(client);
        escrow.cancelJob(jobId);
    }

    // ─── dispute ────────────────────────────────────────────────────────

    function test_dispute_byClient() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, client, keccak256("why"));
        vm.prank(client);
        escrow.dispute(jobId, keccak256("why"));

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Disputed));
    }

    function test_dispute_byProvider() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, provider, keccak256("why"));
        vm.prank(provider);
        escrow.dispute(jobId, keccak256("why"));

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Disputed));
    }

    function test_dispute_byClientOperator_emitsPrincipal() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, client, bytes32(0));
        vm.prank(clientOp);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_dispute_byProviderOperator_emitsPrincipal() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, provider, bytes32(0));
        vm.prank(providerOp);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_noArbiter() public {
        uint256 jobId = _createNoArbiter();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NoArbiter.selector, jobId));
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_notParty() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotParty.selector, jobId));
        vm.prank(stranger);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_notOpen() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Disputed)
        );
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    // ─── resolve ────────────────────────────────────────────────────────

    function _disputed() internal returns (uint256 jobId) {
        jobId = _createDefault();
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_resolve_evenSplit() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobResolved(jobId, 5000, TOTAL / 2, TOTAL / 2, 0);
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Resolved));
        assertEq(job.released, TOTAL / 2);
        assertEq(job.refunded, TOTAL / 2);
        assertEq(usdc.balanceOf(provider), TOTAL / 2);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL / 2);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolve_viaArbiterOperator() public {
        uint256 jobId = _disputed();

        vm.prank(arbiterOp);
        escrow.resolve(jobId, 5000);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Resolved));
    }

    function test_resolve_zeroBps() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(arbiter);
        escrow.resolve(jobId, 0);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, 0);
        assertEq(job.refunded, TOTAL);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
    }

    function test_resolve_fullBps() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(arbiter);
        escrow.resolve(jobId, 10_000);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, TOTAL);
        assertEq(job.refunded, 0);
        assertEq(usdc.balanceOf(provider), TOTAL);
        assertEq(usdc.balanceOf(client), clientBefore);
    }

    function test_resolve_unevenBps() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 toProvider = (TOTAL * 3333) / BPS;
        uint256 toClient = TOTAL - toProvider;

        vm.prank(arbiter);
        escrow.resolve(jobId, 3333);

        assertEq(usdc.balanceOf(provider), toProvider);
        assertEq(usdc.balanceOf(client), clientBefore + toClient);
        assertEq(toProvider + toClient, TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolve_feeAppliesToProviderShareOnly() public {
        _setFee(250);
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 toProvider = TOTAL / 2;
        uint256 fee = (toProvider * 250) / BPS;

        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        assertEq(usdc.balanceOf(provider), toProvider - fee);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL / 2);
        assertEq(usdc.balanceOf(address(feeRouter)), fee);
        assertEq(feeRouter.lastAgent(), provider);
        assertEq(feeRouter.lastAmount(), fee);
    }

    function test_resolve_reputationProviderWon() public {
        _wireModules();
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.negatives(client), 1);
        // Volume recorded is each side's actual settled share, not the whole disputed amount.
        assertEq(reputation.lastValueOf(provider), TOTAL / 2);
        assertEq(reputation.lastValueOf(client), TOTAL - TOTAL / 2);
    }

    function test_resolve_reputationClientWon() public {
        _wireModules();
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, 4999);

        assertEq(reputation.negatives(provider), 1);
        assertEq(reputation.positives(client), 1);
    }

    function test_resolve_afterPartialApproval() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        vm.prank(provider);
        escrow.dispute(jobId, bytes32(0));

        uint256 remaining = TOTAL - M1;
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1 + remaining / 2);
        assertEq(job.refunded, remaining / 2);
        assertEq(usdc.balanceOf(provider), M1 + remaining / 2);
        assertEq(usdc.balanceOf(client), clientBefore + remaining / 2);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolve_zeroProviderShareSkipsFeeRouter() public {
        _setFee(500);
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(arbiter);
        escrow.resolve(jobId, 0);

        assertEq(feeRouter.routeCount(), 0);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_revert_resolve_notArbiter() public {
        uint256 jobId = _disputed();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotArbiter.selector, jobId));
        vm.prank(client);
        escrow.resolve(jobId, 5000);
    }

    function test_revert_resolve_notDisputed() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Open)
        );
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);
    }

    function test_revert_resolve_invalidBps() public {
        uint256 jobId = _disputed();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.InvalidBps.selector, uint16(10_001)));
        vm.prank(arbiter);
        escrow.resolve(jobId, 10_001);
    }

    function test_revert_resolve_twice() public {
        uint256 jobId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Resolved)
        );
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);
    }

    // ─── refundExpired ──────────────────────────────────────────────────

    function test_revert_refundExpired_beforeDeadline() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.refundExpired(jobId);
    }

    function test_revert_refundExpired_atDeadline() public {
        uint256 jobId = _createDefault();
        vm.warp(escrow.getJob(jobId).deadline);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.refundExpired(jobId);
    }

    function test_refundExpired_afterDeadline() public {
        uint256 jobId = _createDefault();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, TOTAL);
        escrow.refundExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(job.refunded, TOTAL);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
    }

    function test_refundExpired_afterPartialApprovals() public {
        uint256 jobId = _createDefault();
        _approveAll(jobId, 2);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        escrow.refundExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1 + M2);
        assertEq(job.refunded, M3);
        assertEq(usdc.balanceOf(client), clientBefore + M3);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_refundExpired_anyoneCanCall() public {
        uint256 jobId = _createDefault();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.prank(stranger);
        escrow.refundExpired(jobId);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    function test_revert_refundExpired_disputedWithinGrace() public {
        uint256 jobId = _disputed();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 30 days);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.refundExpired(jobId);
    }

    function test_refundExpired_disputedAfterGrace() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 30 days + 1);

        escrow.refundExpired(jobId);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
    }

    function test_revert_refundExpired_completed() public {
        uint256 jobId = _createDefault();
        _approveAll(jobId, 3);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Completed)
        );
        escrow.refundExpired(jobId);
    }

    function test_revert_refundExpired_cancelled() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.cancelJob(jobId);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Cancelled)
        );
        escrow.refundExpired(jobId);
    }

    function test_revert_refundExpired_twice() public {
        uint256 jobId = _createDefault();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        escrow.refundExpired(jobId);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Expired)
        );
        escrow.refundExpired(jobId);
    }

    function test_revert_refundExpired_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 7));
        escrow.refundExpired(7);
    }

    // ─── claimable fallback ─────────────────────────────────────────────

    function _failingSetup() internal returns (FailingToken token, AgentEscrowV2 failEscrow) {
        token = new FailingToken();
        failEscrow = new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(failEscrow), type(uint256).max);
    }

    function test_claimable_creditedWhenTransferFails() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        vm.prank(client);
        uint256 jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        token.setBlocked(provider, true);

        vm.expectEmit(true, true, true, true, address(failEscrow));
        emit IAgentEscrowV2.ClaimableAdded(provider, M1);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);

        assertEq(failEscrow.claimable(provider), M1);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(address(failEscrow)), TOTAL);
        assertEq(failEscrow.getJob(jobId).released, M1);
    }

    function test_withdrawClaimable() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        vm.prank(client);
        uint256 jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        token.setBlocked(provider, true);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);

        token.setBlocked(provider, false);

        vm.expectEmit(true, true, true, true, address(failEscrow));
        emit IAgentEscrowV2.ClaimableWithdrawn(provider, M1);
        vm.prank(provider);
        failEscrow.withdrawClaimable();

        assertEq(failEscrow.claimable(provider), 0);
        assertEq(token.balanceOf(provider), M1);
    }

    function test_claimable_accumulatesAcrossMilestones() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        vm.prank(client);
        uint256 jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        token.setBlocked(provider, true);

        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 1);

        assertEq(failEscrow.claimable(provider), M1 + M2);
    }

    function test_claimable_blockedClientOnRefund() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        vm.prank(client);
        uint256 jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        token.setBlocked(client, true);

        vm.prank(client);
        failEscrow.cancelJob(jobId);

        assertEq(failEscrow.claimable(client), TOTAL);
        assertEq(uint8(failEscrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Cancelled));
    }

    function test_revert_withdrawClaimable_nothingToClaim() public {
        vm.expectRevert(IAgentEscrowV2.NothingToClaim.selector);
        vm.prank(stranger);
        escrow.withdrawClaimable();
    }

    // ─── Module hooks ───────────────────────────────────────────────────

    function test_modules_reputationRevertDoesNotBlockApprove() public {
        _wireModules();
        uint256 jobId = _createDefault();
        reputation.setShouldRevert(true);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
        assertEq(reputation.callCount(), 0);
    }

    function test_modules_auditLogRevertDoesNotBlockApprove() public {
        _wireModules();
        uint256 jobId = _createDefault();
        auditLog.setShouldRevert(true);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_modules_auditLogRecordsCreate() public {
        _wireModules();
        _createDefault();

        // _logBoth writes one entry for the client and one for the provider.
        assertEq(auditLog.callCount(), 2);
        assertEq(auditLog.logsOf(client), 1);
        assertEq(auditLog.logsOf(provider), 1);
        assertEq(auditLog.actionCount("ESCROW_JOB_CREATED"), 2);
        assertEq(auditLog.lastValue(), TOTAL);
    }

    function test_modules_auditLogRecordsSubmit() public {
        _wireModules();
        uint256 jobId = _createDefault();

        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));

        assertEq(auditLog.actionCount("ESCROW_MILESTONE_SUBMITTED"), 1);
        assertEq(auditLog.lastAgent(), provider);
    }

    function test_modules_auditLogDataHash() public {
        _wireModules();
        uint256 jobId = _createDefault();

        vm.prank(provider);
        escrow.submitMilestone(jobId, 2, bytes32(0));

        assertEq(auditLog.lastDataHash(), keccak256(abi.encode(jobId, uint8(2))));
        assertEq(auditLog.lastActionType(), bytes32("ESCROW_MILESTONE_SUBMITTED"));
    }

    function test_modules_killSwitchConsumeArgs() public {
        _wireModules();
        _createDefault();

        assertEq(killSwitch.consumeCount(), 1);
        assertEq(killSwitch.lastConsumeAgent(), client);
        assertEq(killSwitch.lastConsumeAmount(), TOTAL);
    }

    function test_revert_create_providerInactive() public {
        _wireModules();
        killSwitch.setInactive(provider, true);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ProviderInactive.selector, provider));
        vm.prank(client);
        escrow.createJob(_defaultParams());
    }

    function test_revert_create_killSwitchConsumeReverts() public {
        _wireModules();
        killSwitch.setConsumeShouldRevert(true);

        vm.expectRevert(MockKillSwitch.MockKillSwitchReverted.selector);
        vm.prank(client);
        escrow.createJob(_defaultParams());
    }

    function test_approve_feeRouterReverts_parksFeeForOwner() public {
        _setFee(250);
        uint256 jobId = _createDefault();
        feeRouter.setShouldRevert(true);
        uint256 amount = escrow.getMilestones(jobId)[0].amount;
        uint256 fee = amount * 250 / 10_000;

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        // Payout proceeds; fee is parked for the owner instead of blocking the job.
        assertEq(usdc.balanceOf(provider) - providerBefore, amount - fee);
        assertEq(escrow.claimable(owner), fee);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    function test_revert_routeFeeSelf_notSelf() public {
        vm.expectRevert(IAgentEscrowV2.NotSelf.selector);
        escrow.routeFeeSelf(provider, 1);
    }

    // ─── Owner ──────────────────────────────────────────────────────────

    function test_setFeeBps() public {
        _wireModules();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.FeeBpsUpdated(0, 500);
        vm.prank(owner);
        escrow.setFeeBps(500);

        assertEq(escrow.feeBps(), 500);
    }

    function test_revert_setFeeBps_tooHigh() public {
        _wireModules();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.FeeTooHigh.selector, 501));
        vm.prank(owner);
        escrow.setFeeBps(501);
    }

    function test_revert_setFeeBps_noRouter() public {
        vm.expectRevert(IAgentEscrowV2.ZeroAddress.selector);
        vm.prank(owner);
        escrow.setFeeBps(1);
    }

    function test_setFeeBps_zeroWithoutRouterOk() public {
        vm.prank(owner);
        escrow.setFeeBps(0);

        assertEq(escrow.feeBps(), 0);
    }

    function test_revert_setFeeBps_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.setFeeBps(100);
    }

    function test_setModules() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.ModulesUpdated(
            address(reputation), address(auditLog), address(killSwitch), address(feeRouter)
        );
        _wireModules();

        assertEq(escrow.reputation(), address(reputation));
        assertEq(escrow.auditLog(), address(auditLog));
        assertEq(escrow.killSwitch(), address(killSwitch));
        assertEq(escrow.feeRouter(), address(feeRouter));
    }

    function test_setModules_clearAllWhenFeeZero() public {
        _wireModules();

        vm.prank(owner);
        escrow.setModules(address(0), address(0), address(0), address(0));

        assertEq(escrow.reputation(), address(0));
        assertEq(escrow.feeRouter(), address(0));
    }

    function test_revert_setModules_clearRouterWhileFeeSet() public {
        _setFee(250);

        vm.expectRevert(IAgentEscrowV2.ZeroAddress.selector);
        vm.prank(owner);
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(0));
    }

    function test_revert_setModules_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.setModules(address(0), address(0), address(0), address(0));
    }

    function test_revert_pause_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.pause();
    }

    function test_revert_unpause_notOwner() public {
        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.unpause();
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function test_revert_getJob_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 0));
        escrow.getJob(0);
    }

    function test_revert_getMilestones_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 3));
        escrow.getMilestones(3);
    }

    function test_getJobsOf_pagination() public {
        for (uint256 i = 0; i < 5; i++) {
            _createDefault();
        }

        uint256[] memory page = escrow.getJobsOf(client, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 2);
    }

    function test_getJobsOf_clipsToLength() public {
        _createDefault();
        _createDefault();

        uint256[] memory page = escrow.getJobsOf(client, 1, 100);
        assertEq(page.length, 1);
        assertEq(page[0], 1);
    }

    function test_getJobsOf_offsetBeyondLength() public {
        _createDefault();
        assertEq(escrow.getJobsOf(client, 1, 10).length, 0);
        assertEq(escrow.getJobsOf(client, 99, 10).length, 0);
    }

    function test_getJobsOf_limitZero() public {
        _createDefault();
        assertEq(escrow.getJobsOf(client, 0, 0).length, 0);
    }

    function test_jobCountOf() public {
        _createDefault();
        _createDefault();

        assertEq(escrow.jobCountOf(client), 2);
        assertEq(escrow.jobCountOf(provider), 2);
        assertEq(escrow.jobCountOf(stranger), 0);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_milestoneAmounts(uint8 count, uint256 seed) public {
        uint256 n = bound(uint256(count), 1, 20);
        uint256[] memory amounts = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1_000_000_000);
            total += amounts[i];
        }

        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, amounts));
        assertEq(escrow.getJob(jobId).total, total);

        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            uint256 before = usdc.balanceOf(provider);
            vm.prank(client);
            escrow.approveMilestone(jobId, uint8(i));
            uint256 delta = usdc.balanceOf(provider) - before;
            assertEq(delta, amounts[i]);
            paid += delta;
        }

        assertEq(paid, total);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(IAgentEscrowV2.JobStatus.Completed));
    }

    function testFuzz_resolveSplit(uint16 providerBps) public {
        uint16 bps = uint16(bound(uint256(providerBps), 0, BPS));
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(arbiter);
        escrow.resolve(jobId, bps);

        uint256 toProvider = (TOTAL * bps) / BPS;
        uint256 toClient = TOTAL - toProvider;

        assertEq(toProvider + toClient, TOTAL);
        assertEq(usdc.balanceOf(provider), toProvider);
        assertEq(usdc.balanceOf(client), clientBefore + toClient);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, toProvider);
        assertEq(job.refunded, toClient);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzz_feeBps(uint256 rawBps) public {
        uint256 bps = bound(rawBps, 0, 500);
        _setFee(bps);
        uint256 jobId = _createDefault();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        uint256 payout = usdc.balanceOf(provider);
        uint256 fee = usdc.balanceOf(address(feeRouter));

        assertEq(fee, (M1 * bps) / BPS);
        assertEq(payout + fee, M1);
        assertEq(feeRouter.totalRouted(), fee);
    }

    function testFuzz_deadlineWithinRange(uint48 rawDeadline) public {
        uint48 deadline = uint48(bound(uint256(rawDeadline), block.timestamp + 1 hours, block.timestamp + 365 days));
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = deadline;

        vm.prank(client);
        uint256 jobId = escrow.createJob(p);

        assertEq(escrow.getJob(jobId).deadline, deadline);
    }

    function testFuzz_createJobRejectsBadDeadline(uint48 rawDeadline) public {
        uint48 deadline = uint48(bound(uint256(rawDeadline), 0, block.timestamp + 1 hours - 1));
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = deadline;

        vm.expectRevert(IAgentEscrowV2.InvalidDeadline.selector);
        vm.prank(client);
        escrow.createJob(p);
    }

    // ─── Balance invariant across a scripted sequence ───────────────────

    /// @notice After a mixed sequence of six jobs the escrow must hold exactly the unreleased,
    ///         unrefunded remainder of every job plus every account's claimable balance.
    function test_balanceInvariantAcrossSequence() public {
        // Job 0: fully approved -> Completed.
        uint256 job0 = _createDefault();
        _approveAll(job0, 3);
        _assertBalanceInvariant(1);

        // Job 1: cancelled with nothing submitted.
        uint256 job1 = _createDefault();
        vm.prank(client);
        escrow.cancelJob(job1);
        _assertBalanceInvariant(2);

        // Job 2: one approval, then left open.
        uint256 job2 = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(job2, 0);
        _assertBalanceInvariant(3);

        // Job 3: disputed and resolved 60/40.
        uint256 job3 = _createDefault();
        vm.prank(provider);
        escrow.dispute(job3, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(job3, 6000);
        _assertBalanceInvariant(4);

        // Job 4: partially approved, then expired.
        uint256 job4 = _createDefault();
        vm.prank(client);
        escrow.approveMilestone(job4, 1);
        _assertBalanceInvariant(5);

        // Job 5: submitted but untouched, expires alongside job 4.
        uint256 job5 = _createDefault();
        vm.prank(provider);
        escrow.submitMilestone(job5, 0, keccak256("d"));
        _assertBalanceInvariant(6);

        vm.warp(uint256(escrow.getJob(job5).deadline) + 1);
        escrow.refundExpired(job4);
        escrow.refundExpired(job5);
        escrow.refundExpired(job2);
        _assertBalanceInvariant(6);

        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
