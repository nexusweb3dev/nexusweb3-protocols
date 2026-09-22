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
    FeeOnTransferToken,
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
    uint256 constant REVIEW_WINDOW = 7 days;
    uint256 constant DISPUTE_GRACE = 30 days;
    uint256 constant MIN_REPUTATION_VALUE = 10_000_000; // $10
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

    /// @dev The default live job: funded offer that the provider has bound itself to.
    function _createAccepted() internal returns (uint256 jobId) {
        jobId = _createDefault();
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function _createAcceptedNoArbiter() internal returns (uint256 jobId) {
        jobId = _createNoArbiter();
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function _submit(uint256 jobId, uint8 index) internal {
        vm.prank(provider);
        escrow.submitMilestone(jobId, index, keccak256(abi.encode("deliverable", index)));
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

    function _status(uint256 jobId) internal view returns (uint8) {
        return uint8(escrow.getJob(jobId).status);
    }

    function _mStatus(uint256 jobId, uint8 index) internal view returns (uint8) {
        return uint8(escrow.getMilestones(jobId)[index].status);
    }

    function _lockedInJobs(uint256 nJobs) internal view returns (uint256 locked) {
        for (uint256 i = 0; i < nJobs; i++) {
            IAgentEscrowV2.Job memory job = escrow.getJob(i);
            locked += job.total - job.released - job.refunded;
        }
    }

    function _assertBalanceInvariant(uint256 nJobs) internal view {
        uint256 expected = _lockedInJobs(nJobs) + escrow.claimable(client) + escrow.claimable(provider)
            + escrow.claimable(arbiter) + escrow.claimable(stranger) + escrow.claimable(owner);
        assertEq(usdc.balanceOf(address(escrow)), expected, "escrow balance != locked + claimable");
    }

    // ─── Constructor & fresh views ──────────────────────────────────────

    function test_constructor() public view {
        assertEq(escrow.paymentToken(), address(usdc));
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), address(0));
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
        assertEq(escrow.MAX_REJECTIONS(), 3);
        assertEq(escrow.MAX_REPUTATION_PER_PAIR(), 10);
        assertEq(escrow.MIN_REPUTATION_VALUE(), MIN_REPUTATION_VALUE);
        assertEq(escrow.MIN_DURATION(), 1 hours);
        assertEq(escrow.MAX_DURATION(), 365 days);
        assertEq(escrow.DISPUTE_GRACE(), DISPUTE_GRACE);
        assertEq(escrow.REVIEW_WINDOW(), REVIEW_WINDOW);
        assertEq(escrow.REPUTATION_CATEGORY(), CATEGORY_ESCROW);
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

    function test_createJob_startsUnaccepted() public {
        IAgentEscrowV2.Job memory job = escrow.getJob(_createDefault());

        assertEq(job.acceptedAt, 0);
        assertEq(job.disputedAt, 0);
        assertFalse(job.everSubmitted);
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
            assertEq(ms[i].rejections, 0);
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

    function test_revert_createJob_clientIsEscrow() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(address(escrow));
        escrow.createJob(_params(address(escrow), provider, arbiter, _amounts3()));
    }

    function test_revert_createJob_providerIsEscrow() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, address(escrow), arbiter, _amounts3()));
    }

    function test_revert_createJob_arbiterIsEscrow() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, address(escrow), _amounts3()));
    }

    function test_revert_createJob_arbiterIsClientOperator() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, clientOp, _amounts3()));
    }

    function test_revert_createJob_arbiterIsProviderOperator() public {
        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, providerOp, _amounts3()));
    }

    function test_revert_createJob_clientIsOperatorOfArbiter() public {
        address captured = makeAddr("capturedArbiterA");
        vm.prank(captured);
        accessControl.authorizeOperator(client, type(uint48).max);

        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, captured, _amounts3()));
    }

    function test_revert_createJob_providerIsOperatorOfArbiter() public {
        address captured = makeAddr("capturedArbiterB");
        vm.prank(captured);
        accessControl.authorizeOperator(provider, type(uint48).max);

        vm.expectRevert(IAgentEscrowV2.InvalidParty.selector);
        vm.prank(client);
        escrow.createJob(_params(client, provider, captured, _amounts3()));
    }

    function test_createJob_independentArbiterWithOwnOperator() public {
        // The arbiter may delegate to its own hot key; that does not tie it to either party.
        uint256 jobId = _createDefault();
        assertEq(escrow.getJob(jobId).arbiter, arbiter);
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

    // ─── createJob: fee-on-transfer tokens ──────────────────────────────

    function _fotSetup(uint256 bps) internal returns (FeeOnTransferToken token, AgentEscrowV2 fotEscrow) {
        token = new FeeOnTransferToken(bps);
        fotEscrow = new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(fotEscrow), type(uint256).max);
    }

    function test_revert_createJob_feeOnTransferToken() public {
        (, AgentEscrowV2 fotEscrow) = _fotSetup(100); // burns 1% of the funding pull
        uint256 received = TOTAL - (TOTAL * 100) / BPS;

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TokenAmountMismatch.selector, TOTAL, received));
        vm.prank(client);
        fotEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
    }

    function test_revert_createJob_feeOnTransferToken_oneBps() public {
        (, AgentEscrowV2 fotEscrow) = _fotSetup(1);
        uint256 received = TOTAL - (TOTAL * 1) / BPS;

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TokenAmountMismatch.selector, TOTAL, received));
        vm.prank(client);
        fotEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
    }

    function test_createJob_zeroFeeOnTransferTokenSucceeds() public {
        (FeeOnTransferToken token, AgentEscrowV2 fotEscrow) = _fotSetup(0);

        vm.prank(client);
        uint256 jobId = fotEscrow.createJob(_params(client, provider, arbiter, _amounts3()));

        assertEq(fotEscrow.getJob(jobId).total, TOTAL);
        assertEq(token.balanceOf(address(fotEscrow)), TOTAL);
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

    // ─── acceptJob ──────────────────────────────────────────────────────

    function test_acceptJob() public {
        uint256 jobId = _createDefault();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobAccepted(jobId);
        vm.prank(provider);
        escrow.acceptJob(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.acceptedAt, uint48(block.timestamp));
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Open));
    }

    function test_acceptJob_viaOperator() public {
        uint256 jobId = _createDefault();

        vm.prank(providerOp);
        escrow.acceptJob(jobId);

        assertEq(escrow.getJob(jobId).acceptedAt, uint48(block.timestamp));
    }

    function test_acceptJob_atDeadlineExactly() public {
        uint256 jobId = _createDefault();
        vm.warp(escrow.getJob(jobId).deadline);

        vm.prank(provider);
        escrow.acceptJob(jobId);

        assertEq(escrow.getJob(jobId).acceptedAt, uint48(block.timestamp));
    }

    function test_acceptJob_logsBothParties() public {
        _wireModules();
        uint256 jobId = _createDefault();
        uint256 before = auditLog.callCount();

        vm.prank(provider);
        escrow.acceptJob(jobId);

        assertEq(auditLog.callCount(), before + 2);
        assertEq(auditLog.actionCount("ESCROW_JOB_ACCEPTED"), 2);
        assertEq(auditLog.lastValue(), TOTAL);
    }

    function test_revert_acceptJob_byClient() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(client);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_byStranger() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(stranger);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_twice() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.AlreadyAccepted.selector, jobId));
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_afterDeadline() public {
        uint256 jobId = _createDefault();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_providerInactive() public {
        _wireModules();
        uint256 jobId = _createDefault();
        killSwitch.setInactive(provider, true);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ProviderInactive.selector, provider));
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_cancelledJob() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.cancelJob(jobId);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Cancelled)
        );
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function test_revert_acceptJob_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 0));
        vm.prank(provider);
        escrow.acceptJob(0);
    }

    function test_acceptJob_worksWhilePaused() public {
        uint256 jobId = _createDefault();
        vm.prank(owner);
        escrow.pause();

        vm.prank(provider);
        escrow.acceptJob(jobId);

        assertGt(escrow.getJob(jobId).acceptedAt, 0);
    }

    // ─── Pre-acceptance gate ────────────────────────────────────────────

    function test_revert_submit_beforeAccept() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_approve_beforeAccept() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
    }

    function test_revert_dispute_beforeAccept() public {
        uint256 jobId = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotAccepted.selector, jobId));
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_cancel_beforeAcceptAlwaysAllowed() public {
        uint256 jobId = _createDefault();
        uint256 before = usdc.balanceOf(client);

        vm.prank(client);
        escrow.cancelJob(jobId);

        assertEq(usdc.balanceOf(client), before + TOTAL);
    }

    // ─── submitMilestone ────────────────────────────────────────────────

    function test_submitMilestone() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneSubmitted(jobId, 0, keccak256("deliverable"));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("deliverable"));

        IAgentEscrowV2.Milestone[] memory ms = escrow.getMilestones(jobId);
        assertEq(uint8(ms[0].status), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
        assertEq(ms[0].deliverableHash, keccak256("deliverable"));
        assertEq(ms[0].submittedAt, uint48(block.timestamp));
    }

    function test_submitMilestone_setsEverSubmitted() public {
        uint256 jobId = _createAccepted();
        assertFalse(escrow.getJob(jobId).everSubmitted);

        _submit(jobId, 0);

        assertTrue(escrow.getJob(jobId).everSubmitted);
    }

    function test_submitMilestone_everSubmittedSurvivesRejection() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertTrue(escrow.getJob(jobId).everSubmitted);
    }

    function test_submitMilestone_viaOperator() public {
        uint256 jobId = _createAccepted();

        vm.prank(providerOp);
        escrow.submitMilestone(jobId, 1, keccak256("d1"));

        assertEq(_mStatus(jobId, 1), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
    }

    function test_submitMilestone_atDeadlineExactly() public {
        uint256 jobId = _createAccepted();
        vm.warp(escrow.getJob(jobId).deadline);

        _submit(jobId, 0);

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
    }

    function test_revert_submit_afterDeadline() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_byClient() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(client);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_byStranger() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(stranger);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_milestoneNotFound() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.MilestoneNotFound.selector, jobId, 3));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 3, bytes32(0));
    }

    function test_revert_submit_alreadySubmitted() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Submitted
            )
        );
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_submit_approved() public {
        uint256 jobId = _createAccepted();
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

    function test_submit_thirdResubmissionStillAllowed() public {
        uint256 jobId = _createAccepted();
        for (uint8 i = 0; i < 2; i++) {
            _submit(jobId, 0);
            vm.prank(client);
            escrow.rejectMilestone(jobId, 0, bytes32(0));
        }

        _submit(jobId, 0); // third attempt: rejections == 2 < MAX_REJECTIONS

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
    }

    function test_revert_submit_tooManyRejections() public {
        uint256 jobId = _createAccepted();
        for (uint8 i = 0; i < 3; i++) {
            _submit(jobId, 0);
            vm.prank(client);
            escrow.rejectMilestone(jobId, 0, bytes32(0));
        }
        assertEq(escrow.getMilestones(jobId)[0].rejections, 3);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.TooManyRejections.selector, jobId, 0));
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));
    }

    function test_submit_rejectionCapIsPerMilestone() public {
        uint256 jobId = _createAccepted();
        for (uint8 i = 0; i < 3; i++) {
            _submit(jobId, 0);
            vm.prank(client);
            escrow.rejectMilestone(jobId, 0, bytes32(0));
        }

        _submit(jobId, 1); // a different milestone has its own budget

        assertEq(_mStatus(jobId, 1), uint8(IAgentEscrowV2.MilestoneStatus.Submitted));
    }

    // ─── approveMilestone ───────────────────────────────────────────────

    function test_approve_withoutSubmit() public {
        uint256 jobId = _createAccepted();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1);
        assertEq(job.approvedCount, 1);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Open));
        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_afterSubmit() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(usdc.balanceOf(provider), M1);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL - M1);
    }

    function test_approve_viaOperator() public {
        uint256 jobId = _createAccepted();

        vm.prank(clientOp);
        escrow.approveMilestone(jobId, 1);

        assertEq(usdc.balanceOf(provider), M2);
    }

    function test_approve_emitsEvent() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneApproved(jobId, 2, M3, 0);
        vm.prank(client);
        escrow.approveMilestone(jobId, 2);
    }

    function test_approve_afterDeadlineStillAllowed() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_noFeeWhenFeeBpsZero() public {
        _wireModules();
        uint256 jobId = _createAccepted();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(escrow.feeBps(), 0);
        assertEq(feeRouter.routeCount(), 0);
        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_withFee() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
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
        uint256 jobId = _createAccepted();
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
        uint256 jobId = _createAccepted();
        _approveAll(jobId, 3);

        assertEq(reputation.positives(provider), 3);
        assertEq(reputation.positives(client), 1);
        assertEq(reputation.lastValueOf(client), TOTAL);
        assertEq(reputation.lastCategory(), CATEGORY_ESCROW);
        assertTrue(reputation.lastPositiveOf(provider));
    }

    function test_approve_reputationPerMilestone() public {
        _wireModules();
        uint256 jobId = _createAccepted();

        vm.prank(client);
        escrow.approveMilestone(jobId, 1);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.lastValueOf(provider), M2);
        assertEq(reputation.positives(client), 0);
    }

    function test_revert_approve_alreadyApproved() public {
        uint256 jobId = _createAccepted();
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
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(provider);
        escrow.approveMilestone(jobId, 0);
    }

    function test_revert_approve_milestoneNotFound() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.MilestoneNotFound.selector, jobId, 9));
        vm.prank(client);
        escrow.approveMilestone(jobId, 9);
    }

    function test_revert_approve_jobNotOpen() public {
        uint256 jobId = _createAccepted();
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
        uint256 jobId = _createAccepted();
        vm.prank(owner);
        escrow.pause();

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    // ─── rejectMilestone ────────────────────────────────────────────────

    function test_reject_submittedBackToPending() public {
        uint256 jobId = _createAccepted();
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
        assertEq(m.rejections, 1);
    }

    function test_reject_incrementsRejectionCounter() public {
        uint256 jobId = _createAccepted();
        for (uint8 i = 0; i < 3; i++) {
            _submit(jobId, 0);
            vm.prank(client);
            escrow.rejectMilestone(jobId, 0, bytes32(0));
            assertEq(escrow.getMilestones(jobId)[0].rejections, i + 1);
        }
    }

    function test_reject_thenResubmit() public {
        uint256 jobId = _createAccepted();
        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d"));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, keccak256("bad"));

        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, keccak256("d2"));

        assertEq(escrow.getMilestones(jobId)[0].deliverableHash, keccak256("d2"));
    }

    function test_reject_viaOperator() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.prank(clientOp);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
    }

    function test_reject_atWindowEdgeStillAllowed() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW);

        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
    }

    function test_revert_reject_afterReviewWindow() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ReviewWindowClosed.selector, jobId, 0));
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_reject_pendingMilestone() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Pending
            )
        );
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_reject_approvedMilestone() public {
        uint256 jobId = _createAccepted();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Approved
            )
        );
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    function test_revert_reject_notClient() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(provider);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
    }

    function test_reject_logsBothParties() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertEq(auditLog.actionCount("ESCROW_MILESTONE_REJECTED"), 2);
    }

    // ─── claimApproval ──────────────────────────────────────────────────

    function test_claimApproval_afterReviewWindow() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.MilestoneClaimed(jobId, 0);
        vm.prank(provider);
        escrow.claimApproval(jobId, 0);

        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_claimApproval_viaOperator() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 1);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.prank(providerOp);
        escrow.claimApproval(jobId, 1);

        assertEq(usdc.balanceOf(provider), M2);
    }

    function test_revert_claimApproval_windowStillOpen() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        uint48 claimableAt = uint48(block.timestamp + REVIEW_WINDOW);
        vm.warp(claimableAt);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.ReviewWindowOpen.selector, jobId, 0, claimableAt));
        vm.prank(provider);
        escrow.claimApproval(jobId, 0);
    }

    function test_revert_claimApproval_notProvider() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotProvider.selector, jobId));
        vm.prank(client);
        escrow.claimApproval(jobId, 0);
    }

    function test_revert_claimApproval_pendingMilestone() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Pending
            )
        );
        vm.prank(provider);
        escrow.claimApproval(jobId, 0);
    }

    function test_revert_claimApproval_afterRejection() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentEscrowV2.WrongMilestoneStatus.selector, jobId, 0, IAgentEscrowV2.MilestoneStatus.Pending
            )
        );
        vm.prank(provider);
        escrow.claimApproval(jobId, 0);
    }

    function test_claimApproval_lastCompletesJob() public {
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(1, M1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);

        vm.prank(provider);
        escrow.claimApproval(jobId, 0);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Completed));
    }

    function test_claimApproval_withFee() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.warp(block.timestamp + REVIEW_WINDOW + 1);
        uint256 fee = (M1 * 250) / BPS;

        vm.prank(provider);
        escrow.claimApproval(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1 - fee);
        assertEq(usdc.balanceOf(address(feeRouter)), fee);
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

    function test_cancel_afterAcceptWhenNothingSubmitted() public {
        uint256 jobId = _createAccepted();
        uint256 before = usdc.balanceOf(client);

        vm.prank(client);
        escrow.cancelJob(jobId);

        assertEq(usdc.balanceOf(client), before + TOTAL);
        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Cancelled));
    }

    function test_cancel_viaOperator() public {
        uint256 jobId = _createDefault();

        vm.prank(clientOp);
        escrow.cancelJob(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Cancelled));
    }

    function test_revert_cancel_afterRejectedSubmission() public {
        // everSubmitted latches: once work was delivered the job can only end by
        // approval, dispute or expiry, even if that delivery was rejected.
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        vm.prank(client);
        escrow.cancelJob(jobId);
    }

    function test_revert_cancel_afterSubmit() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.CannotCancel.selector, jobId));
        vm.prank(client);
        escrow.cancelJob(jobId);
    }

    function test_revert_cancel_afterApproval() public {
        uint256 jobId = _createAccepted();
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

    function test_revert_cancel_byProvider() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotClient.selector, jobId));
        vm.prank(provider);
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

    function test_cancel_afterDeadlineStillAllowed() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.prank(client);
        escrow.cancelJob(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Cancelled));
    }

    // ─── dispute ────────────────────────────────────────────────────────

    function test_dispute_byClient() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, client, keccak256("why"));
        vm.prank(client);
        escrow.dispute(jobId, keccak256("why"));

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Disputed));
        assertEq(job.disputedAt, uint48(block.timestamp));
    }

    function test_dispute_byProvider() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, provider, keccak256("why"));
        vm.prank(provider);
        escrow.dispute(jobId, keccak256("why"));

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Disputed));
    }

    function test_dispute_byClientOperator_emitsPrincipal() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, client, bytes32(0));
        vm.prank(clientOp);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_dispute_byProviderOperator_emitsPrincipal() public {
        uint256 jobId = _createAccepted();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobDisputed(jobId, provider, bytes32(0));
        vm.prank(providerOp);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_dispute_atExpiryExactly() public {
        uint256 jobId = _createAccepted();
        vm.warp(escrow.expiryOf(jobId));

        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Disputed));
    }

    function test_revert_dispute_afterExpiry() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlinePassed.selector, jobId));
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_noArbiter() public {
        uint256 jobId = _createAcceptedNoArbiter();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NoArbiter.selector, jobId));
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_notParty() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotParty.selector, jobId));
        vm.prank(stranger);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_byArbiter() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.NotParty.selector, jobId));
        vm.prank(arbiter);
        escrow.dispute(jobId, bytes32(0));
    }

    function test_revert_dispute_notOpen() public {
        uint256 jobId = _createAccepted();
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
        jobId = _createAccepted();
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

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Resolved));
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

    function test_resolve_evenSplitRecordsNoReputation() public {
        _wireModules();
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);

        assertEq(reputation.callCount(), 0);
        assertEq(reputation.positives(provider), 0);
        assertEq(reputation.negatives(provider), 0);
        assertEq(reputation.positives(client), 0);
        assertEq(reputation.negatives(client), 0);
    }

    function test_resolve_reputationProviderWonAt5001() public {
        _wireModules();
        uint256 jobId = _disputed();
        uint256 toProvider = (TOTAL * 5001) / BPS;

        vm.prank(arbiter);
        escrow.resolve(jobId, 5001);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.negatives(client), 1);
        // Volume recorded is each side's actual settled share, not the whole disputed amount.
        assertEq(reputation.lastValueOf(provider), toProvider);
        assertEq(reputation.lastValueOf(client), TOTAL - toProvider);
    }

    function test_resolve_reputationClientWonAt4999() public {
        _wireModules();
        uint256 jobId = _disputed();
        uint256 toProvider = (TOTAL * 4999) / BPS;

        vm.prank(arbiter);
        escrow.resolve(jobId, 4999);

        assertEq(reputation.negatives(provider), 1);
        assertEq(reputation.positives(client), 1);
        assertEq(reputation.lastValueOf(provider), toProvider);
        assertEq(reputation.lastValueOf(client), TOTAL - toProvider);
    }

    function test_resolve_reputationFullProviderWin() public {
        _wireModules();
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, 10_000);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.negatives(client), 1);
        assertEq(reputation.lastValueOf(client), 0);
    }

    function test_resolve_reputationFullClientWin() public {
        _wireModules();
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, 0);

        assertEq(reputation.negatives(provider), 1);
        assertEq(reputation.positives(client), 1);
        assertEq(reputation.lastValueOf(provider), 0);
    }

    function test_resolve_afterPartialApproval() public {
        uint256 jobId = _createAccepted();
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
        uint256 jobId = _createAccepted();

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

    function test_resolve_afterGraceStillAllowed() public {
        // The grace period opens permissionless settlement; it does not close arbitration.
        uint256 jobId = _disputed();
        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + DISPUTE_GRACE + 1);

        vm.prank(arbiter);
        escrow.resolve(jobId, 7000);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Resolved));
    }

    // ─── settleExpired ──────────────────────────────────────────────────

    function test_revert_settleExpired_beforeDeadline() public {
        uint256 jobId = _createAccepted();

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_atDeadline() public {
        uint256 jobId = _createAccepted();
        vm.warp(escrow.getJob(jobId).deadline);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
    }

    function test_settleExpired_allPendingRefundsClient() public {
        uint256 jobId = _createAccepted();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, 0, TOTAL);
        escrow.settleExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(job.released, 0);
        assertEq(job.refunded, TOTAL);
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
        assertEq(usdc.balanceOf(provider), 0);
    }

    function test_settleExpired_unacceptedOfferRefundsClient() public {
        uint256 jobId = _createDefault();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    function test_settleExpired_submittedVestsToProvider() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 1);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, M2, M1 + M3);
        escrow.settleExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M2);
        assertEq(job.refunded, M1 + M3);
        assertEq(job.approvedCount, 1);
        assertEq(_mStatus(jobId, 1), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(usdc.balanceOf(provider), M2);
        assertEq(usdc.balanceOf(client), clientBefore + M1 + M3);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settleExpired_mixedStatuses() public {
        uint256 jobId = _createAccepted();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0); // Approved: already paid, M1
        _submit(jobId, 1); // Submitted: vests to the provider, M2
        // milestone 2 stays Pending: refunds to the client, M3

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, M2, M3);
        escrow.settleExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1 + M2);
        assertEq(job.refunded, M3);
        assertEq(job.approvedCount, 2);
        assertEq(usdc.balanceOf(provider) - providerBefore, M2);
        assertEq(usdc.balanceOf(client) - clientBefore, M3);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(_mStatus(jobId, 0), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(_mStatus(jobId, 1), uint8(IAgentEscrowV2.MilestoneStatus.Approved));
        assertEq(_mStatus(jobId, 2), uint8(IAgentEscrowV2.MilestoneStatus.Pending));
    }

    function test_settleExpired_feeOnlyOnProviderShare() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
        _submit(jobId, 1);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 fee = (M2 * 250) / BPS;
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M2 - fee);
        assertEq(usdc.balanceOf(address(feeRouter)), fee);
        assertEq(feeRouter.lastAgent(), provider);
        // The client's refund is untouched by the fee.
        assertEq(usdc.balanceOf(client), clientBefore + M1 + M3);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settleExpired_reputationOnlyWhenProviderVests() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        _submit(jobId, 1);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        escrow.settleExpired(jobId);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.lastValueOf(provider), M2);
        assertEq(reputation.negatives(provider), 0);
        assertEq(reputation.positives(client), 0);
        assertEq(reputation.negatives(client), 0);
    }

    function test_settleExpired_noReputationWhenNothingVests() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        escrow.settleExpired(jobId);

        assertEq(reputation.callCount(), 0);
    }

    function test_settleExpired_extendsWithReviewWindow() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) - 1);
        _submit(jobId, 0);

        // Past the deadline but still inside the submission's review window.
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);

        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);
        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_settleExpired_afterPartialApprovals() public {
        uint256 jobId = _createAccepted();
        _approveAll(jobId, 2);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        escrow.settleExpired(jobId);

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.released, M1 + M2);
        assertEq(job.refunded, M3);
        assertEq(usdc.balanceOf(client), clientBefore + M3);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settleExpired_anyoneCanCall() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.prank(stranger);
        escrow.settleExpired(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    function test_settleExpired_logsBothParties() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        escrow.settleExpired(jobId);

        assertEq(auditLog.actionCount("ESCROW_JOB_EXPIRED"), 2);
        assertEq(auditLog.lastValue(), TOTAL);
    }

    function test_revert_settleExpired_disputedAtGraceEdge() public {
        uint256 jobId = _disputed();
        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + DISPUTE_GRACE);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_disputedBeforeGrace() public {
        uint256 jobId = _disputed();
        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + 1 days);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);
    }

    function test_settleExpired_disputedAfterGrace() public {
        uint256 jobId = _disputed();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + DISPUTE_GRACE + 1);

        escrow.settleExpired(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBefore + TOTAL);
    }

    function test_settleExpired_disputedGraceRunsFromDisputeNotDeadline() public {
        // A short-deadline job: the deadline passes long before the dispute grace does.
        IAgentEscrowV2.CreateParams memory p = _defaultParams();
        p.deadline = uint48(block.timestamp + 2 days);
        vm.prank(client);
        uint256 jobId = escrow.createJob(p);
        vm.prank(provider);
        escrow.acceptJob(jobId);
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));

        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.DeadlineNotReached.selector, jobId));
        escrow.settleExpired(jobId);

        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + DISPUTE_GRACE + 1);
        escrow.settleExpired(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    function test_settleExpired_disputedSubmittedWorkVests() public {
        uint256 jobId = _createAccepted();
        _submit(jobId, 2);
        vm.prank(client);
        escrow.dispute(jobId, bytes32(0));
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(uint256(escrow.getJob(jobId).disputedAt) + DISPUTE_GRACE + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, M3, M1 + M2);
        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M3);
        assertEq(usdc.balanceOf(client), clientBefore + M1 + M2);
    }

    function test_revert_settleExpired_completed() public {
        uint256 jobId = _createAccepted();
        _approveAll(jobId, 3);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Completed)
        );
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_cancelled() public {
        uint256 jobId = _createDefault();
        vm.prank(client);
        escrow.cancelJob(jobId);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Cancelled)
        );
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_resolved() public {
        uint256 jobId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(jobId, 5000);
        vm.warp(block.timestamp + DISPUTE_GRACE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Resolved)
        );
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_twice() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        escrow.settleExpired(jobId);

        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrowV2.WrongJobStatus.selector, jobId, IAgentEscrowV2.JobStatus.Expired)
        );
        escrow.settleExpired(jobId);
    }

    function test_revert_settleExpired_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 7));
        escrow.settleExpired(7);
    }

    function test_settleExpired_worksWhilePaused() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        vm.prank(owner);
        escrow.pause();

        escrow.settleExpired(jobId);

        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
    }

    // ─── expiryOf ───────────────────────────────────────────────────────

    function test_expiryOf_defaultsToDeadline() public {
        uint256 jobId = _createAccepted();
        assertEq(escrow.expiryOf(jobId), escrow.getJob(jobId).deadline);
    }

    function test_expiryOf_extendedByLateSubmission() public {
        uint256 jobId = _createAccepted();
        uint48 deadline = escrow.getJob(jobId).deadline;
        vm.warp(uint256(deadline) - 1 days);
        _submit(jobId, 0);

        assertEq(escrow.expiryOf(jobId), uint48(block.timestamp + REVIEW_WINDOW));
    }

    function test_expiryOf_takesLatestSubmission() public {
        uint256 jobId = _createAccepted();
        vm.warp(uint256(escrow.getJob(jobId).deadline) - 3 days);
        _submit(jobId, 0);
        vm.warp(block.timestamp + 1 days);
        _submit(jobId, 1);

        assertEq(escrow.expiryOf(jobId), uint48(block.timestamp + REVIEW_WINDOW));
    }

    function test_expiryOf_rejectionCollapsesExtension() public {
        uint256 jobId = _createAccepted();
        uint48 deadline = escrow.getJob(jobId).deadline;
        vm.warp(uint256(deadline) - 1 days);
        _submit(jobId, 0);
        vm.prank(client);
        escrow.rejectMilestone(jobId, 0, bytes32(0));

        assertEq(escrow.expiryOf(jobId), deadline);
    }

    function test_revert_expiryOf_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrowV2.JobNotFound.selector, 4));
        escrow.expiryOf(4);
    }

    // ─── Reputation pair cap ────────────────────────────────────────────

    function test_reputation_pairCapStopsAtTen() public {
        _wireModules();
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(11, M1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);

        for (uint8 i = 0; i < 11; i++) {
            vm.prank(client);
            escrow.approveMilestone(jobId, i);
        }

        // 11 approvals + 1 completion were attempted; only the first ten were recorded.
        assertEq(reputation.callCount(), 10);
        assertEq(reputation.positives(provider), 10);
        assertEq(reputation.positives(client), 0);
        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Completed));
    }

    function test_reputation_tenthEventStillRecorded() public {
        _wireModules();
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(10, M1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);

        for (uint8 i = 0; i < 10; i++) {
            vm.prank(client);
            escrow.approveMilestone(jobId, i);
        }

        assertEq(reputation.callCount(), 10);
        assertEq(reputation.positives(provider), 10);
        assertEq(reputation.positives(client), 0); // the completion event was the eleventh
    }

    function _singleMilestoneJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(1, M1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    function test_reputation_pairCapSpansJobs() public {
        _wireModules();
        for (uint256 i = 0; i < 5; i++) {
            uint256 jobId = _singleMilestoneJob();
            vm.prank(client);
            escrow.approveMilestone(jobId, 0); // one approval + one completion each
        }
        assertEq(reputation.callCount(), 10);

        uint256 sixth = _singleMilestoneJob();
        vm.prank(client);
        escrow.approveMilestone(sixth, 0);

        assertEq(reputation.callCount(), 10);
        assertEq(reputation.positives(provider), 5);
        assertEq(reputation.positives(client), 5);
    }

    function test_reputation_pairCapCountsExpiryVesting() public {
        _wireModules();
        for (uint256 i = 0; i < 5; i++) {
            uint256 jobId = _singleMilestoneJob();
            vm.prank(client);
            escrow.approveMilestone(jobId, 0);
        }

        uint256 expiring = _singleMilestoneJob();
        _submit(expiring, 0);
        vm.warp(uint256(escrow.expiryOf(expiring)) + 1);
        escrow.settleExpired(expiring);

        // The vesting would have been the eleventh event for this pair.
        assertEq(reputation.callCount(), 10);
        assertEq(usdc.balanceOf(provider), M1 * 6);
    }

    function test_reputation_pairCapIsPerPair() public {
        _wireModules();
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(11, M1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);
        for (uint8 i = 0; i < 11; i++) {
            vm.prank(client);
            escrow.approveMilestone(jobId, i);
        }
        assertEq(reputation.callCount(), 10);

        address provider2 = makeAddr("provider2");
        vm.prank(client);
        uint256 jobId2 = escrow.createJob(_params(client, provider2, arbiter, _amountsN(1, M1)));
        vm.prank(provider2);
        escrow.acceptJob(jobId2);
        vm.prank(client);
        escrow.approveMilestone(jobId2, 0);

        assertEq(reputation.positives(provider2), 1);
        assertEq(reputation.positives(client), 1);
        assertEq(reputation.callCount(), 12);
    }

    function test_reputation_pairCapCountsResolve() public {
        _wireModules();
        for (uint256 i = 0; i < 5; i++) {
            uint256 jobId = _singleMilestoneJob();
            vm.prank(client);
            escrow.approveMilestone(jobId, 0);
        }

        uint256 disputedJob = _singleMilestoneJob();
        vm.prank(client);
        escrow.dispute(disputedJob, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(disputedJob, 9000);

        assertEq(reputation.callCount(), 10);
        assertEq(reputation.negatives(client), 0);
    }

    function test_reputation_dustApprovalNotRecorded() public {
        _wireModules();
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(1, MIN_REPUTATION_VALUE - 1)));
        vm.prank(provider);
        escrow.acceptJob(jobId);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(reputation.callCount(), 0);
        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Completed));
    }

    function test_reputation_atDustThresholdIsRecorded() public {
        _wireModules();
        vm.prank(client);
        uint256 jobId = escrow.createJob(_params(client, provider, arbiter, _amountsN(1, MIN_REPUTATION_VALUE)));
        vm.prank(provider);
        escrow.acceptJob(jobId);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(reputation.positives(provider), 1);
        assertEq(reputation.lastValueOf(provider), MIN_REPUTATION_VALUE);
    }

    /// @dev Documents current behaviour: the pair counter is spent before the dust floor is
    ///      checked, so dust jobs still consume the pair's reputation budget.
    function test_reputation_dustJobsDoNotConsumePairBudget() public {
        _wireModules();
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(client);
            uint256 dustJob = escrow.createJob(_params(client, provider, arbiter, _amountsN(1, 1)));
            vm.prank(provider);
            escrow.acceptJob(dustJob);
            vm.prank(client);
            escrow.approveMilestone(dustJob, 0);
        }
        assertEq(reputation.callCount(), 0);

        uint256 realJob = _singleMilestoneJob();
        vm.prank(client);
        escrow.approveMilestone(realJob, 0);

        // FIXED: dust jobs record nothing and spend nothing; the real job still scores.
        assertEq(reputation.callCount(), 2, "dust must not consume the pair budget");
    }

    /// @dev The pair counter only advances when a reputation event is actually written, so
    ///      history made before a module is wired does not burn the pair's budget.
    function test_reputation_pairBudgetNotSpentWhileModuleUnset() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 jobId = _singleMilestoneJob();
            vm.prank(client);
            escrow.approveMilestone(jobId, 0);
        }

        _wireModules();
        uint256 later = _singleMilestoneJob();
        vm.prank(client);
        escrow.approveMilestone(later, 0);

        assertEq(reputation.callCount(), 2, "budget must survive pre-wiring history");
    }

    // ─── Claimable fallback & withdrawal ────────────────────────────────

    function _failingSetup() internal returns (FailingToken token, AgentEscrowV2 failEscrow) {
        token = new FailingToken();
        failEscrow = new AgentEscrowV2(IAgentAccess(address(accessControl)), IERC20(address(token)), owner);
        token.mint(client, MINT);
        vm.prank(client);
        token.approve(address(failEscrow), type(uint256).max);
    }

    function _failingAccepted() internal returns (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) {
        (token, failEscrow) = _failingSetup();
        vm.prank(client);
        jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        vm.prank(provider);
        failEscrow.acceptJob(jobId);
    }

    function test_claimable_creditedWhenTransferFails() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
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

    function test_withdrawClaimable_selfToSelf() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
        token.setBlocked(provider, true);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);
        token.setBlocked(provider, false);

        vm.expectEmit(true, true, true, true, address(failEscrow));
        emit IAgentEscrowV2.ClaimableWithdrawn(provider, provider, M1);
        vm.prank(provider);
        failEscrow.withdrawClaimable(provider, provider);

        assertEq(failEscrow.claimable(provider), 0);
        assertEq(token.balanceOf(provider), M1);
    }

    function test_withdrawClaimable_blockedProviderViaOperatorToFreshAddress() public {
        // A blacklisted principal is never stuck: its operator drains the parked funds elsewhere.
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
        token.setBlocked(provider, true);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);
        assertEq(failEscrow.claimable(provider), M1);

        address payoutSink = makeAddr("payoutSink");
        vm.expectEmit(true, true, true, true, address(failEscrow));
        emit IAgentEscrowV2.ClaimableWithdrawn(provider, payoutSink, M1);
        vm.prank(providerOp);
        failEscrow.withdrawClaimable(provider, payoutSink);

        assertEq(failEscrow.claimable(provider), 0);
        assertEq(token.balanceOf(payoutSink), M1);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_withdrawClaimable_clientSideViaOperator() public {
        (FailingToken token, AgentEscrowV2 failEscrow) = _failingSetup();
        vm.prank(client);
        uint256 jobId = failEscrow.createJob(_params(client, provider, arbiter, _amounts3()));
        token.setBlocked(client, true);
        vm.prank(client);
        failEscrow.cancelJob(jobId);

        address sink = makeAddr("clientSink");
        vm.prank(clientOp);
        failEscrow.withdrawClaimable(client, sink);

        assertEq(token.balanceOf(sink), TOTAL);
        assertEq(failEscrow.claimable(client), 0);
    }

    function test_claimable_accumulatesAcrossMilestones() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
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

    function test_claimable_blockedPartiesOnSettleExpired() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
        vm.prank(provider);
        failEscrow.submitMilestone(jobId, 0, keccak256("d"));
        token.setBlocked(provider, true);
        token.setBlocked(client, true);
        vm.warp(uint256(failEscrow.expiryOf(jobId)) + 1);

        failEscrow.settleExpired(jobId);

        assertEq(failEscrow.claimable(provider), M1);
        assertEq(failEscrow.claimable(client), M2 + M3);
        assertEq(token.balanceOf(address(failEscrow)), TOTAL);
    }

    function test_revert_withdrawClaimable_nothingToClaim() public {
        vm.expectRevert(IAgentEscrowV2.NothingToClaim.selector);
        vm.prank(stranger);
        escrow.withdrawClaimable(stranger, stranger);
    }

    function test_revert_withdrawClaimable_zeroDestination() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
        token.setBlocked(provider, true);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);

        vm.expectRevert(IAgentEscrowV2.ZeroAddress.selector);
        vm.prank(provider);
        failEscrow.withdrawClaimable(provider, address(0));
    }

    function test_revert_withdrawClaimable_notAgentOrOperator() public {
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, provider, stranger));
        vm.prank(stranger);
        escrow.withdrawClaimable(provider, stranger);
    }

    function test_revert_withdrawClaimable_twice() public {
        (FailingToken token, AgentEscrowV2 failEscrow, uint256 jobId) = _failingAccepted();
        token.setBlocked(provider, true);
        vm.prank(client);
        failEscrow.approveMilestone(jobId, 0);
        token.setBlocked(provider, false);
        vm.prank(provider);
        failEscrow.withdrawClaimable(provider, provider);

        vm.expectRevert(IAgentEscrowV2.NothingToClaim.selector);
        vm.prank(provider);
        failEscrow.withdrawClaimable(provider, provider);
    }

    // ─── Module hooks ───────────────────────────────────────────────────

    function test_modules_reputationRevertDoesNotBlockApprove() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        reputation.setShouldRevert(true);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
        assertEq(reputation.callCount(), 0);
    }

    function test_modules_auditLogRevertDoesNotBlockApprove() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        auditLog.setShouldRevert(true);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_modules_auditLogRevertDoesNotBlockSettleExpired() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        _submit(jobId, 0);
        auditLog.setShouldRevert(true);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M1);
        assertEq(_status(jobId), uint8(IAgentEscrowV2.JobStatus.Expired));
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
        uint256 jobId = _createAccepted();

        vm.prank(provider);
        escrow.submitMilestone(jobId, 0, bytes32(0));

        assertEq(auditLog.actionCount("ESCROW_MILESTONE_SUBMITTED"), 1);
        assertEq(auditLog.lastAgent(), provider);
    }

    function test_modules_auditLogDataHash() public {
        _wireModules();
        uint256 jobId = _createAccepted();

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

    function test_inactiveProvider_stillPaidOnExistingJob() public {
        _wireModules();
        uint256 jobId = _createAccepted();
        killSwitch.setInactive(provider, true);

        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(usdc.balanceOf(provider), M1);
    }

    function test_approve_feeRouterReverts_parksFeeForOwner() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
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

    function test_settleExpired_feeRouterReverts_parksFeeForOwner() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
        _submit(jobId, 1);
        feeRouter.setShouldRevert(true);
        uint256 fee = (M2 * 250) / BPS;
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider), M2 - fee);
        assertEq(escrow.claimable(owner), fee);
    }

    function test_ownerWithdrawsParkedFee() public {
        _setFee(250);
        uint256 jobId = _createAccepted();
        feeRouter.setShouldRevert(true);
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);
        uint256 fee = (M1 * 250) / BPS;

        vm.prank(owner);
        escrow.withdrawClaimable(owner, owner);

        assertEq(usdc.balanceOf(owner), fee);
        assertEq(escrow.claimable(owner), 0);
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

    // ─── Ownable2Step ───────────────────────────────────────────────────

    function test_transferOwnership_isTwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        assertEq(escrow.owner(), owner, "owner must not change before acceptance");
        assertEq(escrow.pendingOwner(), newOwner);
    }

    function test_acceptOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        vm.prank(newOwner);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), newOwner);
        assertEq(escrow.pendingOwner(), address(0));
    }

    function test_revert_acceptOwnership_notPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.acceptOwnership();
    }

    function test_revert_transferOwnership_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.transferOwnership(stranger);
    }

    function test_oldOwnerKeepsPowersUntilAcceptance() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        escrow.pause();

        vm.prank(owner);
        escrow.pause();
        assertTrue(escrow.paused());
    }

    function test_newOwnerControlsAfterAcceptance() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        vm.prank(newOwner);
        escrow.acceptOwnership();

        vm.prank(newOwner);
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
        vm.prank(newOwner);
        escrow.setFeeBps(100);

        assertEq(escrow.feeBps(), 100);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        escrow.setFeeBps(0);
    }

    function test_parkedFeeFollowsCurrentOwner() public {
        _setFee(250);
        feeRouter.setShouldRevert(true);
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        vm.prank(newOwner);
        escrow.acceptOwnership();

        uint256 jobId = _createAccepted();
        vm.prank(client);
        escrow.approveMilestone(jobId, 0);

        assertEq(escrow.claimable(newOwner), (M1 * 250) / BPS);
        assertEq(escrow.claimable(owner), 0);
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
        vm.prank(provider);
        escrow.acceptJob(jobId);
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

    function testFuzz_resolveReputationDirection(uint16 providerBps) public {
        _wireModules();
        uint16 bps = uint16(bound(uint256(providerBps), 0, BPS));
        uint256 jobId = _disputed();

        vm.prank(arbiter);
        escrow.resolve(jobId, bps);

        if (bps == 5000) {
            assertEq(reputation.callCount(), 0);
        } else if (bps > 5000) {
            assertEq(reputation.positives(provider), 1);
            assertEq(reputation.negatives(client), 1);
        } else {
            assertEq(reputation.negatives(provider), 1);
            assertEq(reputation.positives(client), 1);
        }
    }

    function testFuzz_feeBps(uint256 rawBps) public {
        uint256 bps = bound(rawBps, 0, 500);
        _setFee(bps);
        uint256 jobId = _createAccepted();

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

    /// @notice Whatever mix of Pending/Submitted/Approved a job expires in, settlement pays the
    ///         provider exactly the Submitted amounts and refunds the client everything else.
    function testFuzz_settleExpiredStatusMix(uint256 seed) public {
        uint256 jobId = _createAccepted();
        uint256[3] memory amounts = [M1, M2, M3];
        uint256 approvedTotal;
        uint256 submittedTotal;

        for (uint8 i = 0; i < 3; i++) {
            // Milestone 0 never gets approved, so the job can never reach Completed.
            uint256 pick = uint256(keccak256(abi.encode(seed, i))) % (i == 0 ? 2 : 3);
            if (pick == 1) {
                _submit(jobId, i);
                submittedTotal += amounts[i];
            } else if (pick == 2) {
                vm.prank(client);
                escrow.approveMilestone(jobId, i);
                approvedTotal += amounts[i];
            }
        }

        uint256 expectedToClient = TOTAL - approvedTotal - submittedTotal;
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.warp(uint256(escrow.expiryOf(jobId)) + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrowV2.JobExpired(jobId, submittedTotal, expectedToClient);
        escrow.settleExpired(jobId);

        assertEq(usdc.balanceOf(provider) - providerBefore, submittedTotal, "provider share");
        assertEq(usdc.balanceOf(client) - clientBefore, expectedToClient, "client share");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow drained");

        IAgentEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgentEscrowV2.JobStatus.Expired));
        assertEq(job.released, approvedTotal + submittedTotal);
        assertEq(job.refunded, expectedToClient);
        assertEq(job.released + job.refunded, TOTAL);
    }

    // ─── Balance invariant across a scripted sequence ───────────────────

    /// @notice After a mixed sequence of seven jobs the escrow must hold exactly the unreleased,
    ///         unrefunded remainder of every job plus every account's claimable balance.
    function test_balanceInvariantAcrossSequence() public {
        // Job 0: accepted and fully approved -> Completed.
        uint256 job0 = _createAccepted();
        _approveAll(job0, 3);
        _assertBalanceInvariant(1);

        // Job 1: cancelled as an unaccepted offer.
        uint256 job1 = _createDefault();
        vm.prank(client);
        escrow.cancelJob(job1);
        _assertBalanceInvariant(2);

        // Job 2: accepted, one approval, then left open.
        uint256 job2 = _createAccepted();
        vm.prank(client);
        escrow.approveMilestone(job2, 0);
        _assertBalanceInvariant(3);

        // Job 3: disputed and resolved 60/40.
        uint256 job3 = _createAccepted();
        vm.prank(provider);
        escrow.dispute(job3, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(job3, 6000);
        _assertBalanceInvariant(4);

        // Job 4: partially approved, then settled at expiry (nothing submitted).
        uint256 job4 = _createAccepted();
        vm.prank(client);
        escrow.approveMilestone(job4, 1);
        _assertBalanceInvariant(5);

        // Job 5: one milestone submitted and never reviewed; it vests at settlement.
        uint256 job5 = _createAccepted();
        _submit(job5, 0);
        _assertBalanceInvariant(6);

        // Job 6: accepted offer nobody ever touched, and a milestone rejected back to Pending.
        uint256 job6 = _createAccepted();
        _submit(job6, 2);
        vm.prank(client);
        escrow.rejectMilestone(job6, 2, bytes32(0));
        _assertBalanceInvariant(7);

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(uint256(escrow.expiryOf(job5)) + 1);
        escrow.settleExpired(job4);
        escrow.settleExpired(job5);
        escrow.settleExpired(job2);
        escrow.settleExpired(job6);
        _assertBalanceInvariant(7);

        // Only job 5's submitted milestone vested; everything else went back to the client.
        assertEq(usdc.balanceOf(provider) - providerBefore, M1);
        assertEq(
            usdc.balanceOf(client) - clientBefore,
            (TOTAL - M1) // job 2: milestone 0 was approved
                + (TOTAL - M2) // job 4: milestone 1 was approved
                + (TOTAL - M1) // job 5: milestone 0 vested to the provider
                + TOTAL, // job 6: the rejected milestone went back to Pending
            "refunds across job2, job4, job5, job6"
        );
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
