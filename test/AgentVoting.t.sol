// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentVoting} from "../src/AgentVoting.sol";
import {AgentReputation} from "../src/AgentReputation.sol";
import {IAgentVoting} from "../src/interfaces/IAgentVoting.sol";

contract AgentVotingTest is Test {
    AgentReputation rep;
    AgentVoting voting;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");

    uint256 constant CREATE_FEE = 0.001 ether;
    uint256 constant VOTE_FEE = 0.0001 ether;

    function setUp() public {
        rep = new AgentReputation(treasury, owner, 0);
        voting = new AgentVoting(address(rep), treasury, owner, CREATE_FEE, VOTE_FEE);

        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(agent3, 10 ether);

        // give agent1 high reputation
        vm.prank(owner);
        rep.authorizeProtocol(address(this));
        rep.recordInteraction(agent1, true, 0); // 110
        rep.recordInteraction(agent1, true, 0); // 120
    }

    function _deadline() internal view returns (uint48) {
        return uint48(block.timestamp + 1 days);
    }

    function _options2() internal pure returns (string[] memory) {
        string[] memory opts = new string[](2);
        opts[0] = "Yes";
        opts[1] = "No";
        return opts;
    }

    function _options3() internal pure returns (string[] memory) {
        string[] memory opts = new string[](3);
        opts[0] = "Option A";
        opts[1] = "Option B";
        opts[2] = "Option C";
        return opts;
    }

    function _createDefaultPoll() internal returns (uint256) {
        vm.prank(agent1);
        return voting.createPoll{value: CREATE_FEE}("Test Poll", _options2(), _deadline(), false);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(voting.treasury(), treasury);
        assertEq(voting.owner(), owner);
        assertEq(voting.creationFee(), CREATE_FEE);
        assertEq(voting.voteFee(), VOTE_FEE);
        assertEq(voting.pollCount(), 0);
    }

    function test_revert_constructorZeroReputation() public {
        vm.expectRevert(IAgentVoting.ZeroAddress.selector);
        new AgentVoting(address(0), treasury, owner, CREATE_FEE, VOTE_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentVoting.ZeroAddress.selector);
        new AgentVoting(address(rep), address(0), owner, CREATE_FEE, VOTE_FEE);
    }

    // ─── Create Poll ────────────────────────────────────────────────────

    function test_createPoll() public {
        uint256 id = _createDefaultPoll();

        assertEq(id, 0);
        assertEq(voting.pollCount(), 1);

        IAgentVoting.Poll memory p = voting.getPoll(id);
        assertEq(p.creator, agent1);
        assertEq(p.options.length, 2);
        assertFalse(p.closed);
        assertFalse(p.reputationWeighted);
    }

    function test_createWeightedPoll() public {
        vm.prank(agent1);
        uint256 id = voting.createPoll{value: CREATE_FEE}("Weighted", _options3(), _deadline(), true);

        IAgentVoting.Poll memory p = voting.getPoll(id);
        assertTrue(p.reputationWeighted);
        assertEq(p.options.length, 3);
    }

    function test_createCollectsFee() public {
        _createDefaultPoll();
        assertEq(voting.accumulatedFees(), CREATE_FEE);
    }

    function test_revert_createEmptyTitle() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentVoting.EmptyTitle.selector);
        voting.createPoll{value: CREATE_FEE}("", _options2(), _deadline(), false);
    }

    function test_revert_createTooFewOptions() public {
        string[] memory opts = new string[](1);
        opts[0] = "Only one";

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.TooFewOptions.selector, 1));
        voting.createPoll{value: CREATE_FEE}("Bad", opts, _deadline(), false);
    }

    function test_revert_createTooManyOptions() public {
        string[] memory opts = new string[](11);
        for (uint i; i < 11; i++) opts[i] = "opt";

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.TooManyOptions.selector, 11));
        voting.createPoll{value: CREATE_FEE}("Bad", opts, _deadline(), false);
    }

    function test_revert_createDeadlineTooSoon() public {
        vm.prank(agent1);
        vm.expectRevert();
        voting.createPoll{value: CREATE_FEE}("Bad", _options2(), uint48(block.timestamp + 30 minutes), false);
    }

    function test_revert_createInsufficientFee() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.InsufficientFee.selector, CREATE_FEE, 0));
        voting.createPoll("Poll", _options2(), _deadline(), false);
    }

    function test_revert_createWhenPaused() public {
        vm.prank(owner);
        voting.pause();

        vm.prank(agent1);
        vm.expectRevert();
        voting.createPoll{value: CREATE_FEE}("Poll", _options2(), _deadline(), false);
    }

    // ─── Vote ───────────────────────────────────────────────────────────

    function test_castVote() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, 0); // vote Yes

        assertTrue(voting.hasVoted(id, agent1));
        assertEq(voting.getVote(id, agent1), 0);
    }

    function test_voteMultipleVoters() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, 0);
        vm.prank(agent2);
        voting.castVote{value: VOTE_FEE}(id, 1);
        vm.prank(agent3);
        voting.castVote{value: VOTE_FEE}(id, 0);

        (uint256 winIdx, uint256 winVotes) = voting.getResult(id);
        assertEq(winIdx, 0); // Yes wins 2-1
        assertEq(winVotes, 2);
    }

    function test_reputationWeightedVote() public {
        vm.prank(agent1);
        uint256 id = voting.createPoll{value: CREATE_FEE}("Weighted", _options2(), _deadline(), true);

        // agent1 has rep 120, agent2 has rep 100 (default)
        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, 1); // No with weight 120

        vm.prank(agent2);
        voting.castVote{value: VOTE_FEE}(id, 0); // Yes with weight 100

        (uint256 winIdx, uint256 winVotes) = voting.getResult(id);
        assertEq(winIdx, 1); // No wins 120 vs 100
        assertEq(winVotes, 120);
    }

    function test_revert_voteAlreadyVoted() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, 0);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.AlreadyVoted.selector, id, agent1));
        voting.castVote{value: VOTE_FEE}(id, 1);
    }

    function test_revert_voteInvalidOption() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.InvalidOption.selector, id, 5));
        voting.castVote{value: VOTE_FEE}(id, 5);
    }

    function test_revert_voteAfterDeadline() public {
        uint256 id = _createDefaultPoll();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.PollNotActive.selector, id));
        voting.castVote{value: VOTE_FEE}(id, 0);
    }

    function test_revert_voteInsufficientFee() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.InsufficientFee.selector, VOTE_FEE, 0));
        voting.castVote(id, 0);
    }

    function test_revert_voteClosed() public {
        uint256 id = _createDefaultPoll();

        vm.warp(block.timestamp + 1 days + 1);
        voting.closePoll(id);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.PollNotActive.selector, id));
        voting.castVote{value: VOTE_FEE}(id, 0);
    }

    // ─── Close ──────────────────────────────────────────────────────────

    function test_closePoll() public {
        uint256 id = _createDefaultPoll();

        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, 0);

        vm.warp(block.timestamp + 1 days + 1);
        voting.closePoll(id);

        IAgentVoting.Poll memory p = voting.getPoll(id);
        assertTrue(p.closed);
    }

    function test_revert_closeBeforeDeadline() public {
        uint256 id = _createDefaultPoll();

        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.PollNotEnded.selector, id));
        voting.closePoll(id);
    }

    function test_revert_closeAlreadyClosed() public {
        uint256 id = _createDefaultPoll();

        vm.warp(block.timestamp + 1 days + 1);
        voting.closePoll(id);

        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.PollNotActive.selector, id));
        voting.closePoll(id);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _createDefaultPoll();

        uint256 treasuryBefore = treasury.balance;
        voting.collectFees();
        assertEq(treasury.balance - treasuryBefore, CREATE_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentVoting.NoFeesToCollect.selector);
        voting.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setCreationFee() public {
        vm.prank(owner);
        voting.setCreationFee(0.005 ether);
        assertEq(voting.creationFee(), 0.005 ether);
    }

    function test_setVoteFee() public {
        vm.prank(owner);
        voting.setVoteFee(0.0005 ether);
        assertEq(voting.voteFee(), 0.0005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        voting.setTreasury(newT);
        assertEq(voting.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentVoting.ZeroAddress.selector);
        voting.setTreasury(address(0));
    }

    function test_revert_getPollNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentVoting.PollNotFound.selector, 999));
        voting.getPoll(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_createAndVote(uint256 optionIdx) public {
        uint256 id = _createDefaultPoll();
        optionIdx = bound(optionIdx, 0, 1);

        vm.prank(agent1);
        voting.castVote{value: VOTE_FEE}(id, optionIdx);

        assertEq(voting.getVote(id, agent1), optionIdx);
    }

    function testFuzz_feeAccumulates(uint8 voters) public {
        voters = uint8(bound(voters, 1, 50));
        uint256 id = _createDefaultPoll();

        for (uint i; i < voters; i++) {
            address v = makeAddr(string(abi.encode("voter", i)));
            vm.deal(v, 1 ether);
            vm.prank(v);
            voting.castVote{value: VOTE_FEE}(id, i % 2);
        }

        assertEq(voting.accumulatedFees(), CREATE_FEE + uint256(voters) * VOTE_FEE);
    }
}
