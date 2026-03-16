// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NexusToken} from "../src/NexusToken.sol";
import {AgentGovernance} from "../src/AgentGovernance.sol";
import {IAgentGovernance} from "../src/interfaces/IAgentGovernance.sol";

contract AgentGovernanceTest is Test {
    NexusToken nexus;
    AgentGovernance governance;

    address owner = makeAddr("owner");
    address proposer = makeAddr("proposer");
    address voter1 = makeAddr("voter1");
    address voter2 = makeAddr("voter2");
    address voter3 = makeAddr("voter3");
    address nobody = makeAddr("nobody");

    uint256 constant TOTAL_SUPPLY = 100_000_000e18; // 100M NEXUS
    uint256 constant PROPOSAL_THRESHOLD = 100e18;
    uint256 constant TIMELOCK = 2 days;

    // dummy target for proposal execution
    address target;

    function setUp() public {
        nexus = new NexusToken(owner, TOTAL_SUPPLY);
        governance = new AgentGovernance(IERC20(address(nexus)), owner);

        // distribute tokens from owner
        vm.startPrank(owner);
        nexus.transfer(proposer, 10_000_000e18); // 10M (10%)
        nexus.transfer(voter1, 5_000_000e18); // 5M (5%)
        nexus.transfer(voter2, 3_000_000e18); // 3M (3%)
        nexus.transfer(voter3, 1_000_000e18); // 1M (1%)
        vm.stopPrank();

        // deploy a dummy target contract that accepts calls
        target = address(new DummyTarget());
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(governance.nexusToken()), address(nexus));
        assertEq(governance.owner(), owner);
        assertEq(governance.proposalCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentGovernance.ZeroAddress.selector);
        new AgentGovernance(IERC20(address(0)), owner);
    }

    // ─── Create Proposal ────────────────────────────────────────────────

    function test_createProposal() public {
        bytes memory callData = abi.encodeWithSignature("setValue(uint256)", 42);

        vm.prank(proposer);
        uint256 id = governance.createProposal("Set value to 42", callData, target, 3);

        assertEq(id, 0);
        assertEq(governance.proposalCount(), 1);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.proposer, proposer);
        assertEq(p.title, "Set value to 42");
        assertEq(p.target, target);
        assertEq(p.forVotes, 0);
        assertEq(p.againstVotes, 0);
        assertEq(p.snapshotSupply, TOTAL_SUPPLY);
        assertTrue(p.state == IAgentGovernance.ProposalState.Active);
        assertEq(p.voteEnd, p.voteStart + uint48(3 days));
        assertEq(p.executableAfter, p.voteEnd + uint48(TIMELOCK));
    }

    function test_revert_createProposalBelowThreshold() public {
        vm.prank(nobody); // nobody has 0 tokens
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.InsufficientTokens.selector, PROPOSAL_THRESHOLD, 0));
        governance.createProposal("bad", "", target, 1);
    }

    function test_revert_createProposalZeroTarget() public {
        vm.prank(proposer);
        vm.expectRevert(IAgentGovernance.InvalidTarget.selector);
        governance.createProposal("bad", "", address(0), 1);
    }

    function test_revert_createProposalInvalidVotingDays_zero() public {
        vm.prank(proposer);
        vm.expectRevert(IAgentGovernance.InvalidVotingPeriod.selector);
        governance.createProposal("bad", "", target, 0);
    }

    function test_revert_createProposalInvalidVotingDays_tooLong() public {
        vm.prank(proposer);
        vm.expectRevert(IAgentGovernance.InvalidVotingPeriod.selector);
        governance.createProposal("bad", "", target, 15);
    }

    function test_revert_createProposalWhenPaused() public {
        vm.prank(owner);
        governance.pause();

        vm.prank(proposer);
        vm.expectRevert();
        governance.createProposal("paused", "", target, 1);
    }

    // ─── Voting ─────────────────────────────────────────────────────────

    function test_voteFor() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("vote test", "", target, 3);

        vm.prank(voter1);
        governance.vote(id, true);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.forVotes, 5_000_000e18);
        assertEq(p.againstVotes, 0);
    }

    function test_voteAgainst() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("against test", "", target, 3);

        vm.prank(voter2);
        governance.vote(id, false);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.forVotes, 0);
        assertEq(p.againstVotes, 3_000_000e18);
    }

    function test_multipleVoters() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("multi voter", "", target, 3);

        vm.prank(voter1);
        governance.vote(id, true);
        vm.prank(voter2);
        governance.vote(id, true);
        vm.prank(voter3);
        governance.vote(id, false);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.forVotes, 8_000_000e18); // voter1 + voter2
        assertEq(p.againstVotes, 1_000_000e18); // voter3
    }

    function test_revert_voteTwice() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("double vote", "", target, 3);

        vm.prank(voter1);
        governance.vote(id, true);

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.AlreadyVoted.selector, id, voter1));
        governance.vote(id, true);
    }

    function test_revert_voteAfterDeadline() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("expired vote", "", target, 1);

        // warp past the 1 day voting period
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotActive.selector, id));
        governance.vote(id, true);
    }

    function test_revert_voteZeroBalance() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("no balance vote", "", target, 3);

        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.InsufficientTokens.selector, 1, 0));
        governance.vote(id, true);
    }

    function test_revert_voteWhenPaused() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("pause vote", "", target, 3);

        vm.prank(owner);
        governance.pause();

        vm.prank(voter1);
        vm.expectRevert();
        governance.vote(id, true);
    }

    // ─── Execute Proposal ───────────────────────────────────────────────

    function test_executeProposal() public {
        bytes memory callData = abi.encodeWithSignature("setValue(uint256)", 99);

        vm.prank(proposer);
        uint256 id = governance.createProposal("exec test", callData, target, 1);

        // proposer + voter1 + voter2 vote for (18M total, >10M quorum)
        vm.prank(proposer);
        governance.vote(id, true);
        vm.prank(voter1);
        governance.vote(id, true);

        // warp past voting + timelock
        vm.warp(block.timestamp + 1 days + TIMELOCK + 1);

        governance.executeProposal(id);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.state == IAgentGovernance.ProposalState.Executed);
        assertEq(DummyTarget(target).value(), 99);
    }

    function test_revert_executeBeforeVotingEnds() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("too early", "", target, 3);

        vm.prank(proposer);
        governance.vote(id, true);

        // still within voting period
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotPassed.selector, id));
        governance.executeProposal(id);
    }

    function test_revert_executeBeforeTimelockExpires() public {
        bytes memory callData = abi.encodeWithSignature("setValue(uint256)", 1);

        vm.prank(proposer);
        uint256 id = governance.createProposal("timelock test", callData, target, 1);

        vm.prank(proposer);
        governance.vote(id, true);
        vm.prank(voter1);
        governance.vote(id, true);

        // warp past voting but NOT past timelock
        vm.warp(block.timestamp + 1 days + 1);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.TimelockNotExpired.selector, id, p.executableAfter));
        governance.executeProposal(id);
    }

    function test_revert_executeQuorumNotReached() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("no quorum", "", target, 1);

        // only voter3 votes (1M = 1%, quorum is 10%)
        vm.prank(voter3);
        governance.vote(id, true);

        vm.warp(block.timestamp + 1 days + TIMELOCK + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.QuorumNotReached.selector, id));
        governance.executeProposal(id);
    }

    function test_revert_executeFailedProposal_moreAgainst() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("will fail", "", target, 1);

        // voter1 for (5M), proposer against (10M)
        vm.prank(voter1);
        governance.vote(id, true);
        vm.prank(proposer);
        governance.vote(id, false);

        vm.warp(block.timestamp + 1 days + TIMELOCK + 1);

        // the revert rolls back the state change to Failed, so state remains Active
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotPassed.selector, id));
        governance.executeProposal(id);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.state == IAgentGovernance.ProposalState.Active);
    }

    function test_revert_executeAlreadyExecuted() public {
        bytes memory callData = abi.encodeWithSignature("setValue(uint256)", 1);

        vm.prank(proposer);
        uint256 id = governance.createProposal("exec twice", callData, target, 1);

        vm.prank(proposer);
        governance.vote(id, true);
        vm.prank(voter1);
        governance.vote(id, true);

        vm.warp(block.timestamp + 1 days + TIMELOCK + 1);

        governance.executeProposal(id);

        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotPassed.selector, id));
        governance.executeProposal(id);
    }

    // ─── Cancel Proposal ────────────────────────────────────────────────

    function test_cancelProposal() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("cancel me", "", target, 3);

        vm.prank(owner);
        governance.cancelProposal(id);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.state == IAgentGovernance.ProposalState.Cancelled);
    }

    function test_revert_cancelProposalNotOwner() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("not your proposal", "", target, 3);

        vm.prank(proposer);
        vm.expectRevert();
        governance.cancelProposal(id);
    }

    function test_revert_cancelAlreadyCancelled() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("double cancel", "", target, 3);

        vm.prank(owner);
        governance.cancelProposal(id);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotActive.selector, id));
        governance.cancelProposal(id);
    }

    function test_revert_voteOnCancelledProposal() public {
        vm.prank(proposer);
        uint256 id = governance.createProposal("cancelled vote", "", target, 3);

        vm.prank(owner);
        governance.cancelProposal(id);

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IAgentGovernance.ProposalNotActive.selector, id));
        governance.vote(id, true);
    }

    // ─── Pause / Unpause ────────────────────────────────────────────────

    function test_pauseUnpause() public {
        vm.prank(owner);
        governance.pause();

        vm.prank(proposer);
        vm.expectRevert();
        governance.createProposal("paused", "", target, 1);

        vm.prank(owner);
        governance.unpause();

        vm.prank(proposer);
        uint256 id = governance.createProposal("unpaused", "", target, 1);
        assertEq(id, 0);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_votingWeights(uint256 weight1, uint256 weight2) public {
        weight1 = bound(weight1, 1e18, 10_000_000e18);
        weight2 = bound(weight2, 1e18, 10_000_000e18);

        address fuzzVoter1 = makeAddr("fuzzVoter1");
        address fuzzVoter2 = makeAddr("fuzzVoter2");

        vm.startPrank(owner);
        nexus.transfer(fuzzVoter1, weight1);
        nexus.transfer(fuzzVoter2, weight2);
        vm.stopPrank();

        vm.prank(proposer);
        uint256 id = governance.createProposal("fuzz vote", "", target, 3);

        vm.prank(fuzzVoter1);
        governance.vote(id, true);
        vm.prank(fuzzVoter2);
        governance.vote(id, false);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.forVotes, weight1);
        assertEq(p.againstVotes, weight2);
    }

    function testFuzz_votingDays(uint256 days_) public {
        days_ = bound(days_, 1, 14);

        vm.prank(proposer);
        uint256 id = governance.createProposal("fuzz days", "", target, days_);

        IAgentGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.voteEnd, p.voteStart + uint48(days_ * 1 days));
    }

    function testFuzz_votingDays_revertOutOfRange(uint256 days_) public {
        // 0 or > 14
        days_ = bound(days_, 15, 1000);

        vm.prank(proposer);
        vm.expectRevert(IAgentGovernance.InvalidVotingPeriod.selector);
        governance.createProposal("fuzz days revert", "", target, days_);
    }
}

// minimal target that governance proposals can call
contract DummyTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }
}
