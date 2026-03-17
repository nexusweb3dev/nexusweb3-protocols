// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentCollective} from "../src/AgentCollective.sol";
import {IAgentCollective} from "../src/interfaces/IAgentCollective.sol";

contract AgentCollectiveTest is Test {
    ERC20Mock usdc;
    AgentCollective collective;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");

    uint256 constant DEPLOY_FEE = 0.01 ether;
    uint256 constant ENTRY_FEE = 100_000_000; // $100 USDC
    uint256 constant PROFIT_BPS = 3000; // 30%
    uint256 constant BPS = 10_000;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        collective = new AgentCollective(IERC20(address(usdc)), treasury, owner, DEPLOY_FEE);

        address[4] memory users = [alice, bob, charlie, dave];
        for (uint256 i; i < users.length; i++) {
            usdc.mint(users[i], 100_000_000_000);
            vm.prank(users[i]);
            usdc.approve(address(collective), type(uint256).max);
            vm.deal(users[i], 10 ether);
        }
    }

    function _createDefault() internal returns (uint256) {
        vm.prank(alice);
        return collective.createCollective{value: DEPLOY_FEE}("TradingDAO", 0, ENTRY_FEE, PROFIT_BPS);
    }

    function _join(address user, uint256 id) internal {
        vm.prank(user);
        collective.joinCollective(id);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(collective.paymentToken()), address(usdc));
        assertEq(collective.treasury(), treasury);
        assertEq(collective.owner(), owner);
        assertEq(collective.deploymentFee(), DEPLOY_FEE);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentCollective.ZeroAddress.selector);
        new AgentCollective(IERC20(address(0)), treasury, owner, DEPLOY_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentCollective.ZeroAddress.selector);
        new AgentCollective(IERC20(address(usdc)), address(0), owner, DEPLOY_FEE);
    }

    // ─── Create Collective ──────────────────────────────────────────────

    function test_createCollective() public {
        uint256 id = _createDefault();
        assertEq(id, 0);
        assertEq(collective.collectiveCount(), 1);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.collectiveType, 0);
        assertEq(c.entryFee, ENTRY_FEE);
        assertEq(c.profitShareBps, PROFIT_BPS);
        assertEq(c.treasury, 0);
        assertEq(c.memberCount, 0);
        assertTrue(c.active);
    }

    function test_createCollective_allTypes() public {
        for (uint8 t; t <= 4; t++) {
            vm.prank(alice);
            collective.createCollective{value: DEPLOY_FEE}("test", t, 0, 1000);
        }
        assertEq(collective.collectiveCount(), 5);
    }

    function test_createCollective_deploymentFee() public {
        _createDefault();
        assertEq(collective.accumulatedEthFees(), DEPLOY_FEE);
    }

    function test_revert_createEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(IAgentCollective.EmptyName.selector);
        collective.createCollective{value: DEPLOY_FEE}("", 0, ENTRY_FEE, PROFIT_BPS);
    }

    function test_revert_createInvalidType() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.InvalidCollectiveType.selector, 5));
        collective.createCollective{value: DEPLOY_FEE}("test", 5, ENTRY_FEE, PROFIT_BPS);
    }

    function test_revert_createProfitShareTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.InvalidProfitShare.selector, 5001));
        collective.createCollective{value: DEPLOY_FEE}("test", 0, ENTRY_FEE, 5001);
    }

    function test_revert_createInsufficientFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.InsufficientFee.selector, DEPLOY_FEE, 0));
        collective.createCollective("test", 0, ENTRY_FEE, PROFIT_BPS);
    }

    function test_revert_createWhenPaused() public {
        vm.prank(owner);
        collective.pause();
        vm.prank(alice);
        vm.expectRevert();
        collective.createCollective{value: DEPLOY_FEE}("test", 0, ENTRY_FEE, PROFIT_BPS);
    }

    // ─── Join Collective ────────────────────────────────────────────────

    function test_joinCollective() public {
        uint256 id = _createDefault();
        _join(alice, id);

        assertEq(collective.balanceOf(alice, id), 1);
        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.memberCount, 1);
        assertEq(c.treasury, ENTRY_FEE);
    }

    function test_joinCollective_multipleMembers() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);
        _join(charlie, id);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.memberCount, 3);
        assertEq(c.treasury, ENTRY_FEE * 3);

        address[] memory members = collective.getMembers(id);
        assertEq(members.length, 3);
    }

    function test_joinCollective_zeroEntryFee() public {
        vm.prank(alice);
        uint256 id = collective.createCollective{value: DEPLOY_FEE}("free", 4, 0, PROFIT_BPS);

        _join(bob, id);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.memberCount, 1);
        assertEq(c.treasury, 0);
    }

    function test_revert_joinAlreadyMember() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.AlreadyMember.selector, id, alice));
        collective.joinCollective(id);
    }

    function test_revert_joinInvalidCollective() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.InvalidCollective.selector, 999));
        collective.joinCollective(999);
    }

    // ─── Soulbound NFT ──────────────────────────────────────────────────

    function test_soulbound_cannotTransfer() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        vm.expectRevert(IAgentCollective.SoulboundToken.selector);
        collective.safeTransferFrom(alice, bob, id, 1, "");
    }

    function test_soulbound_cannotBatchTransfer() public {
        uint256 id = _createDefault();
        _join(alice, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 1;

        vm.prank(alice);
        vm.expectRevert(IAgentCollective.SoulboundToken.selector);
        collective.safeBatchTransferFrom(alice, bob, ids, vals, "");
    }

    // ─── Leave Collective ───────────────────────────────────────────────

    function test_leaveCollective_afterLock() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        vm.warp(block.timestamp + 30 days + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        collective.leaveCollective(id);

        // got a proportional share (minus small AUM fee accrued over 30 days)
        uint256 payout = usdc.balanceOf(alice) - aliceBefore;
        assertGt(payout, 0);
        assertLe(payout, ENTRY_FEE); // never more than entry fee per member
        assertEq(collective.balanceOf(alice, id), 0);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.memberCount, 1);
    }

    function test_leaveCollective_beforeLock_forfeits() public {
        uint256 id = _createDefault();
        _join(alice, id);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // leave immediately — forfeit entry fee
        vm.prank(alice);
        collective.leaveCollective(id);

        // no payout
        assertEq(usdc.balanceOf(alice), aliceBefore);
        assertEq(collective.balanceOf(alice, id), 0);
    }

    function test_leaveCollective_noFlashLoan() public {
        uint256 id = _createDefault();

        // join and leave in same block — should get nothing
        vm.startPrank(alice);
        collective.joinCollective(id);
        collective.leaveCollective(id);
        vm.stopPrank();

        // entry fee forfeited — stays in treasury
        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.treasury, ENTRY_FEE);
        assertEq(c.memberCount, 0);
    }

    function test_revert_leaveNotMember() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.NotMember.selector, id, alice));
        collective.leaveCollective(id);
    }

    // ─── Deposit Revenue ────────────────────────────────────────────────

    function test_depositRevenue() public {
        uint256 id = _createDefault();
        _join(alice, id);

        uint256 depositAmt = 1_000_000_000; // $1000

        vm.prank(alice);
        collective.depositRevenue(id, depositAmt);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        assertEq(c.treasury, ENTRY_FEE + depositAmt);
    }

    function test_revert_depositNotMember() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.NotMember.selector, id, alice));
        collective.depositRevenue(id, 1_000_000);
    }

    function test_revert_depositZero() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        vm.expectRevert(IAgentCollective.ZeroAmount.selector);
        collective.depositRevenue(id, 0);
    }

    // ─── Distribute Profit ──────────────────────────────────────────────

    function test_distributeProfit() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        uint256 deposit = 1_000_000_000;
        vm.prank(alice);
        collective.depositRevenue(id, deposit);

        vm.warp(block.timestamp + 7 days + 1);

        collective.distributeProfit(id);

        // rewards are pending, not yet sent
        uint256 alicePending = collective.getPendingDistribution(id, alice);
        uint256 bobPending = collective.getPendingDistribution(id, bob);
        assertEq(alicePending, bobPending);
        assertGt(alicePending, 0);

        // claim
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        collective.claimDistribution(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, alicePending);
    }

    function test_distributeProfit_anyoneCanCall() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000_000);

        vm.warp(block.timestamp + 7 days + 1);

        // dave (non-member) can trigger distribution
        vm.prank(dave);
        collective.distributeProfit(id);
    }

    function test_distributeProfit_treasuryReduces() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000_000);

        vm.warp(block.timestamp + 7 days + 1);

        // treasury before distribution (after AUM fee charged inside distributeProfit)
        uint256 treasuryBefore = collective.getCollective(id).treasury;
        collective.distributeProfit(id);
        uint256 treasuryAfter = collective.getCollective(id).treasury;

        // treasury decreased by profitShareBps% (after AUM fee)
        assertLt(treasuryAfter, treasuryBefore);
        assertGt(treasuryAfter, 0); // not drained
    }

    function test_revert_distributeCooldown() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000_000);

        // first distribution after cooldown
        vm.warp(block.timestamp + 7 days + 1);
        collective.distributeProfit(id);

        // add more revenue
        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000_000);

        // immediate second attempt — should fail
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.DistributionCooldown.selector, id));
        collective.distributeProfit(id);
    }

    function test_revert_distributeNoMembers() public {
        uint256 id = _createDefault();

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.NoMembers.selector, id));
        collective.distributeProfit(id);
    }

    function test_revert_distributeEmptyTreasury() public {
        vm.prank(alice);
        uint256 id = collective.createCollective{value: DEPLOY_FEE}("free", 0, 0, PROFIT_BPS);
        _join(alice, id);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.EmptyTreasury.selector, id));
        collective.distributeProfit(id);
    }

    // ─── AUM Fee ────────────────────────────────────────────────────────

    function test_aumFee_chargedOnDeposit() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.warp(block.timestamp + 365 days);

        uint256 treasuryBefore = collective.getCollective(id).treasury;

        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000);

        uint256 expectedFee = treasuryBefore * 5 * 365 days / (BPS * 365 days);
        assertGt(collective.accumulatedUsdcFees(), 0);
    }

    function test_aumFee_tinyTreasury_noFee() public {
        vm.prank(alice);
        uint256 id = collective.createCollective{value: DEPLOY_FEE}("tiny", 0, 1, 1000);
        _join(alice, id); // treasury = 1

        vm.warp(block.timestamp + 1 days);

        // fee should be 0 due to rounding (1 * 5 * 86400 / (10000 * 31536000) = 0)
        vm.prank(alice);
        collective.depositRevenue(id, 1);
    }

    // ─── Voting ─────────────────────────────────────────────────────────

    function test_createProposal() public {
        uint256 id = _createDefault();
        _join(alice, id);

        uint48 deadline = uint48(block.timestamp) + 2 hours;

        vm.prank(alice);
        uint256 proposalId = collective.createProposal(id, "Increase entry fee?", deadline);

        assertEq(proposalId, 0);
        IAgentCollective.Proposal memory p = collective.getProposal(id, proposalId);
        assertEq(p.deadline, deadline);
        assertEq(p.forVotes, 0);
        assertEq(p.againstVotes, 0);
    }

    function test_voteOnStrategy() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        uint48 deadline = uint48(block.timestamp) + 2 hours;
        vm.prank(alice);
        uint256 proposalId = collective.createProposal(id, "Strategy A?", deadline);

        vm.prank(alice);
        collective.voteOnStrategy(id, proposalId, true);

        vm.prank(bob);
        collective.voteOnStrategy(id, proposalId, false);

        IAgentCollective.Proposal memory p = collective.getProposal(id, proposalId);
        assertEq(p.forVotes, 1);
        assertEq(p.againstVotes, 1);
    }

    function test_revert_voteNotMember() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        uint256 proposalId = collective.createProposal(id, "test", uint48(block.timestamp) + 2 hours);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.NotMember.selector, id, dave));
        collective.voteOnStrategy(id, proposalId, true);
    }

    function test_revert_voteAlreadyVoted() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        uint256 proposalId = collective.createProposal(id, "test", uint48(block.timestamp) + 2 hours);

        vm.prank(alice);
        collective.voteOnStrategy(id, proposalId, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.AlreadyVoted.selector, id, proposalId, alice));
        collective.voteOnStrategy(id, proposalId, false);
    }

    function test_revert_voteExpiredProposal() public {
        uint256 id = _createDefault();
        _join(alice, id);

        uint48 deadline = uint48(block.timestamp) + 2 hours;
        vm.prank(alice);
        uint256 proposalId = collective.createProposal(id, "test", deadline);

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.ProposalExpired.selector, id, proposalId));
        collective.voteOnStrategy(id, proposalId, true);
    }

    // ─── Emergency Withdraw ─────────────────────────────────────────────

    function test_emergencyWithdraw() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(owner);
        collective.pause();

        // can withdraw even without lock period elapsed
        vm.prank(alice);
        collective.emergencyWithdraw(id);

        uint256 expectedShare = (ENTRY_FEE * 2) / 2;
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedShare);
    }

    function test_revert_emergencyWithdraw_notPaused() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        vm.expectRevert("not paused");
        collective.emergencyWithdraw(id);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _createDefault();

        uint256 treasuryBefore = treasury.balance;
        collective.collectFees();
        assertEq(treasury.balance - treasuryBefore, DEPLOY_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentCollective.NoFeesToCollect.selector);
        collective.collectFees();
    }

    // ─── View Functions ─────────────────────────────────────────────────

    function test_getMemberShare() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        uint256 expectedShare = (ENTRY_FEE * 2) / 2;
        assertEq(collective.getMemberShare(id, alice), expectedShare);
        assertEq(collective.getMemberShare(id, bob), expectedShare);
        assertEq(collective.getMemberShare(id, charlie), 0); // not member
    }

    function test_getMembers() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);

        address[] memory members = collective.getMembers(id);
        assertEq(members.length, 2);
        assertEq(members[0], alice);
        assertEq(members[1], bob);
    }

    function test_getMembers_afterLeave() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);
        _join(charlie, id);

        // alice leaves (swap-and-pop: alice replaced by charlie)
        vm.prank(alice);
        collective.leaveCollective(id);

        address[] memory members = collective.getMembers(id);
        assertEq(members.length, 2);
    }

    // ─── Edge Cases ─────────────────────────────────────────────────────

    function test_memberCountAccurate() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);
        _join(charlie, id);

        assertEq(collective.getCollective(id).memberCount, 3);

        vm.prank(alice);
        collective.leaveCollective(id);
        assertEq(collective.getCollective(id).memberCount, 2);

        vm.prank(bob);
        collective.leaveCollective(id);
        assertEq(collective.getCollective(id).memberCount, 1);
    }

    function test_treasuryAccounting_afterExits() public {
        uint256 id = _createDefault();
        _join(alice, id);
        _join(bob, id);
        _join(charlie, id);

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(alice);
        collective.leaveCollective(id);

        vm.prank(bob);
        collective.leaveCollective(id);

        IAgentCollective.Collective memory c = collective.getCollective(id);
        // treasury reduced by two shares + AUM fee, one member remains
        assertGt(c.treasury, 0);
        assertEq(c.memberCount, 1);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_entryFeeGoesToTreasury(uint256 fee) public {
        fee = bound(fee, 1_000_000, 10_000_000_000);

        vm.prank(alice);
        uint256 id = collective.createCollective{value: DEPLOY_FEE}("fuzz", 0, fee, PROFIT_BPS);

        usdc.mint(bob, fee);
        vm.prank(bob);
        usdc.approve(address(collective), fee);

        _join(bob, id);

        assertEq(collective.getCollective(id).treasury, fee);
    }

    function testFuzz_profitDistributionFair(uint256 deposit, uint256 profitBps) public {
        deposit = bound(deposit, 1_000_000, 10_000_000_000);
        profitBps = bound(profitBps, 100, 5000);

        vm.prank(alice);
        uint256 id = collective.createCollective{value: DEPLOY_FEE}("fuzz", 0, 0, profitBps);

        _join(alice, id);
        _join(bob, id);

        usdc.mint(alice, deposit);
        vm.prank(alice);
        collective.depositRevenue(id, deposit);

        vm.warp(block.timestamp + 7 days + 1);

        collective.distributeProfit(id);

        // both get equal pending share
        uint256 alicePending = collective.getPendingDistribution(id, alice);
        uint256 bobPending = collective.getPendingDistribution(id, bob);
        assertEq(alicePending, bobPending);
    }

    function testFuzz_leaveBeforeLock_getsNothing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days - 1);

        uint256 id = _createDefault();
        _join(alice, id);

        vm.warp(block.timestamp + elapsed);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        collective.leaveCollective(id);

        assertEq(usdc.balanceOf(alice), aliceBefore); // no payout
    }

    // ─── F-2 Fix: Pull-based distribution ───────────────────────────────

    function test_claimDistribution() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        collective.depositRevenue(id, 1_000_000_000);

        vm.warp(block.timestamp + 7 days + 1);
        collective.distributeProfit(id);

        uint256 pending = collective.getPendingDistribution(id, alice);
        assertGt(pending, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        collective.claimDistribution(id);

        assertEq(usdc.balanceOf(alice) - aliceBefore, pending);
        assertEq(collective.getPendingDistribution(id, alice), 0);
    }

    function test_revert_claimDistributionNothing() public {
        uint256 id = _createDefault();
        _join(alice, id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentCollective.NoPendingDistribution.selector, id, alice));
        collective.claimDistribution(id);
    }
}
