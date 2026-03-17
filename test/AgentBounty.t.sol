// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentBounty} from "../src/AgentBounty.sol";
import {IAgentBounty} from "../src/interfaces/IAgentBounty.sol";

contract AgentBountyTest is Test {
    ERC20Mock usdc;
    AgentBounty bounty;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address poster = makeAddr("poster");
    address solver1 = makeAddr("solver1");
    address solver2 = makeAddr("solver2");

    uint256 constant FEE_BPS = 200; // 2%
    uint256 constant BPS = 10_000;
    uint256 constant REWARD = 100_000_000; // $100
    bytes32 constant VALIDATION = keccak256("correct-answer");
    bytes32 constant WRONG = keccak256("wrong-answer");

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        bounty = new AgentBounty(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        usdc.mint(poster, 10_000_000_000);
        vm.prank(poster);
        usdc.approve(address(bounty), type(uint256).max);
    }

    function _deadline() internal view returns (uint48) {
        return uint48(block.timestamp + 1 days);
    }

    function _postDefault() internal returns (uint256) {
        vm.prank(poster);
        return bounty.postBounty("Find bug", "Find the vuln", REWARD, _deadline(), VALIDATION);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(bounty.treasury(), treasury);
        assertEq(bounty.platformFeeBps(), FEE_BPS);
        assertEq(bounty.bountyCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentBounty.ZeroAddress.selector);
        new AgentBounty(IERC20(address(0)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.FeeTooHigh.selector, 1001));
        new AgentBounty(IERC20(address(usdc)), treasury, owner, 1001);
    }

    // ─── Post Bounty ────────────────────────────────────────────────────

    function test_postBounty() public {
        uint256 id = _postDefault();
        assertEq(id, 0);
        assertEq(bounty.bountyCount(), 1);

        IAgentBounty.Bounty memory b = bounty.getBounty(id);
        assertEq(b.poster, poster);
        assertEq(b.reward, REWARD);
        assertEq(b.validationHash, VALIDATION);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Open));
    }

    function test_postTakesFeeAndReward() public {
        uint256 fee = REWARD * FEE_BPS / BPS;
        uint256 posterBefore = usdc.balanceOf(poster);

        _postDefault();

        assertEq(posterBefore - usdc.balanceOf(poster), REWARD + fee);
        assertEq(bounty.accumulatedFees(), fee);
    }

    function test_revert_postEmptyTitle() public {
        vm.prank(poster);
        vm.expectRevert(IAgentBounty.EmptyTitle.selector);
        bounty.postBounty("", "reqs", REWARD, _deadline(), VALIDATION);
    }

    function test_revert_postLowReward() public {
        vm.prank(poster);
        vm.expectRevert(IAgentBounty.InvalidReward.selector);
        bounty.postBounty("T", "R", 999_999, _deadline(), VALIDATION);
    }

    function test_revert_postZeroValidationHash() public {
        vm.prank(poster);
        vm.expectRevert(IAgentBounty.InvalidValidationHash.selector);
        bounty.postBounty("T", "R", REWARD, _deadline(), bytes32(0));
    }

    function test_revert_postDeadlineTooSoon() public {
        vm.prank(poster);
        vm.expectRevert(IAgentBounty.InvalidDeadline.selector);
        bounty.postBounty("T", "R", REWARD, uint48(block.timestamp + 30 minutes), VALIDATION);
    }

    // ─── Submit Solution ────────────────────────────────────────────────

    function test_submitCorrectSolution() public {
        uint256 id = _postDefault();

        uint256 solverBefore = usdc.balanceOf(solver1);
        vm.prank(solver1);
        bounty.submitSolution(id, VALIDATION);

        // auto-validated — reward paid
        IAgentBounty.Bounty memory b = bounty.getBounty(id);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Completed));
        assertEq(b.winner, solver1);

        uint256 paid = usdc.balanceOf(solver1) - solverBefore + bounty.getClaimable(solver1);
        assertEq(paid, REWARD);
    }

    function test_submitWrongSolution() public {
        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, WRONG);

        IAgentBounty.Bounty memory b = bounty.getBounty(id);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Open)); // still open
        assertEq(b.submissionCount, 1);
    }

    function test_revert_submitDuplicate() public {
        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, WRONG);

        vm.prank(solver1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.AlreadySubmitted.selector, id, solver1));
        bounty.submitSolution(id, VALIDATION);
    }

    function test_revert_submitAfterDeadline() public {
        uint256 id = _postDefault();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(solver1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.BountyExpired.selector, id));
        bounty.submitSolution(id, VALIDATION);
    }

    function test_revert_submitToCompleted() public {
        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, VALIDATION); // completes it

        vm.prank(solver2);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.BountyNotOpen.selector, id));
        bounty.submitSolution(id, VALIDATION);
    }

    function test_submissionRecorded() public {
        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, WRONG);

        IAgentBounty.Submission[] memory subs = bounty.getSubmissions(id);
        assertEq(subs.length, 1);
        assertEq(subs[0].submitter, solver1);
        assertEq(subs[0].solutionHash, WRONG);
    }

    // ─── Manual Approve ─────────────────────────────────────────────────

    function test_manualApprove() public {
        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, WRONG); // wrong hash, but submitted

        uint256 solverBefore = usdc.balanceOf(solver1);
        vm.prank(poster);
        bounty.manualApprove(id, solver1);

        IAgentBounty.Bounty memory b = bounty.getBounty(id);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Completed));
        assertEq(b.winner, solver1);

        uint256 paid = usdc.balanceOf(solver1) - solverBefore + bounty.getClaimable(solver1);
        assertEq(paid, REWARD);
    }

    function test_revert_manualApproveNotPoster() public {
        uint256 id = _postDefault();
        vm.prank(solver1);
        bounty.submitSolution(id, WRONG);

        vm.prank(solver2);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.NotPoster.selector, id));
        bounty.manualApprove(id, solver1);
    }

    function test_revert_manualApproveNoSubmission() public {
        uint256 id = _postDefault();

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.InvalidSolution.selector, id));
        bounty.manualApprove(id, solver1); // solver1 hasn't submitted
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    function test_cancelBounty() public {
        uint256 id = _postDefault();

        uint256 posterBefore = usdc.balanceOf(poster);
        vm.prank(poster);
        bounty.cancelBounty(id);

        assertEq(usdc.balanceOf(poster) - posterBefore, REWARD); // reward refunded, fee kept
        assertEq(uint8(bounty.getBounty(id).status), uint8(IAgentBounty.BountyStatus.Cancelled));
    }

    function test_revert_cancelWithSubmissions() public {
        uint256 id = _postDefault();
        vm.prank(solver1);
        bounty.submitSolution(id, WRONG);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.BountyHasSubmissions.selector, id));
        bounty.cancelBounty(id);
    }

    function test_revert_cancelNotPoster() public {
        uint256 id = _postDefault();
        vm.prank(solver1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.NotPoster.selector, id));
        bounty.cancelBounty(id);
    }

    // ─── Expire ─────────────────────────────────────────────────────────

    function test_expireBounty() public {
        uint256 id = _postDefault();
        vm.warp(block.timestamp + 1 days + 1);

        uint256 posterBefore = usdc.balanceOf(poster);
        bounty.expireBounty(id);

        assertEq(usdc.balanceOf(poster) - posterBefore + bounty.getClaimable(poster), REWARD);
        assertEq(uint8(bounty.getBounty(id).status), uint8(IAgentBounty.BountyStatus.Expired));
    }

    function test_revert_expireBeforeDeadline() public {
        uint256 id = _postDefault();
        vm.expectRevert(IAgentBounty.InvalidDeadline.selector);
        bounty.expireBounty(id);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        _postDefault();
        uint256 before_ = usdc.balanceOf(treasury);
        bounty.collectFees();
        uint256 expectedFee = REWARD * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(treasury) - before_, expectedFee);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentBounty.NoFeesToCollect.selector);
        bounty.collectFees();
    }

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        bounty.setPlatformFeeBps(300);
        assertEq(bounty.platformFeeBps(), 300);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        bounty.setTreasury(newT);
        assertEq(bounty.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentBounty.ZeroAddress.selector);
        bounty.setTreasury(address(0));
    }

    function test_revert_getBountyNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentBounty.BountyNotFound.selector, 999));
        bounty.getBounty(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_postAndSolve(uint256 reward) public {
        reward = bound(reward, 1_000_000, 1_000_000_000);

        uint256 fee = reward * FEE_BPS / BPS;
        usdc.mint(poster, reward + fee);

        vm.prank(poster);
        uint256 id = bounty.postBounty("Fuzz", "Solve", reward, _deadline(), VALIDATION);

        uint256 solverBefore = usdc.balanceOf(solver1);
        vm.prank(solver1);
        bounty.submitSolution(id, VALIDATION);

        uint256 paid = usdc.balanceOf(solver1) - solverBefore + bounty.getClaimable(solver1);
        assertEq(paid, reward);
    }

    function testFuzz_wrongSolutionStaysOpen(bytes32 wrongHash) public {
        vm.assume(wrongHash != VALIDATION && wrongHash != bytes32(0));

        uint256 id = _postDefault();

        vm.prank(solver1);
        bounty.submitSolution(id, wrongHash);

        assertEq(uint8(bounty.getBounty(id).status), uint8(IAgentBounty.BountyStatus.Open));
    }
}
