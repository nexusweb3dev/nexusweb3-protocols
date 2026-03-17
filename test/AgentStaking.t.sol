// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentStaking} from "../src/AgentStaking.sol";
import {IAgentStaking} from "../src/interfaces/IAgentStaking.sol";

contract AgentStakingTest is Test {
    ERC20Mock nexus;
    AgentStaking staking;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address protocol1 = makeAddr("protocol1");

    uint256 constant STAKE_AMT = 1000e18;

    function setUp() public {
        nexus = new ERC20Mock("NexusWeb3", "NEXUS", 18);
        staking = new AgentStaking(IERC20(address(nexus)), treasury, owner);

        nexus.mint(alice, 100_000e18);
        nexus.mint(bob, 100_000e18);

        vm.prank(alice);
        nexus.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        nexus.approve(address(staking), type(uint256).max);

        vm.prank(owner);
        staking.authorizeProtocol(protocol1);
    }

    function _stakeDefault() internal returns (uint256) {
        vm.prank(alice);
        return staking.stake(STAKE_AMT, 7); // flexible, 1x boost
    }

    function _addRevenue(uint256 amount) internal {
        vm.deal(protocol1, amount);
        vm.prank(protocol1);
        staking.addRevenue{value: amount}();
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(staking.nexusToken()), address(nexus));
        assertEq(staking.treasury(), treasury);
        assertEq(staking.owner(), owner);
        assertEq(staking.totalWeightedStake(), 0);
        assertEq(staking.getBoost(7), 10000);
        assertEq(staking.getBoost(30), 12500);
        assertEq(staking.getBoost(90), 15000);
        assertEq(staking.getBoost(180), 20000);
        assertEq(staking.getBoost(365), 30000);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentStaking.ZeroAddress.selector);
        new AgentStaking(IERC20(address(0)), treasury, owner);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentStaking.ZeroAddress.selector);
        new AgentStaking(IERC20(address(nexus)), address(0), owner);
    }

    // ─── Stake ──────────────────────────────────────────────────────────

    function test_stakeMinLock() public {
        uint256 id = _stakeDefault(); // 7-day min lock

        IAgentStaking.StakeInfo memory s = staking.getStake(id);
        assertEq(s.owner, alice);
        assertEq(s.amount, STAKE_AMT);
        assertEq(s.weightedAmount, STAKE_AMT); // 1x boost
        assertEq(s.lockUntil, uint48(block.timestamp + 7 days));
        assertTrue(s.active);
        assertEq(staking.totalWeightedStake(), STAKE_AMT);
    }

    function test_stakeLocked30() public {
        vm.prank(alice);
        uint256 id = staking.stake(STAKE_AMT, 30);

        IAgentStaking.StakeInfo memory s = staking.getStake(id);
        assertEq(s.weightedAmount, STAKE_AMT * 12500 / 10000); // 1.25x
        assertEq(s.lockUntil, uint48(block.timestamp + 30 days));
    }

    function test_stakeLocked365() public {
        vm.prank(alice);
        uint256 id = staking.stake(STAKE_AMT, 365);

        IAgentStaking.StakeInfo memory s = staking.getStake(id);
        assertEq(s.weightedAmount, STAKE_AMT * 30000 / 10000); // 3x
    }

    function test_stakeTransfersTokens() public {
        uint256 balBefore = nexus.balanceOf(alice);
        _stakeDefault();
        assertEq(balBefore - nexus.balanceOf(alice), STAKE_AMT);
        assertEq(nexus.balanceOf(address(staking)), STAKE_AMT);
    }

    function test_multipleStakes() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMT, 7);
        staking.stake(STAKE_AMT, 90);
        vm.stopPrank();

        uint256[] memory ids = staking.getUserStakes(alice);
        assertEq(ids.length, 2);
        assertEq(staking.stakeCount(), 2);
    }

    function test_revert_stakeZero() public {
        vm.prank(alice);
        vm.expectRevert(IAgentStaking.ZeroAmount.selector);
        staking.stake(0, 7);
    }

    function test_revert_stakeInvalidLock() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.InvalidLockPeriod.selector, 45));
        staking.stake(STAKE_AMT, 45);
    }

    function test_revert_stakeWhenPaused() public {
        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(STAKE_AMT, 7);
    }

    // ─── Unstake ────────────────────────────────────────────────────────

    function test_unstakeAfter7DayLock() public {
        uint256 id = _stakeDefault();

        vm.warp(block.timestamp + 8 days);

        uint256 balBefore = nexus.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(id);

        assertEq(nexus.balanceOf(alice) - balBefore, STAKE_AMT);
        assertFalse(staking.getStake(id).active);
        assertEq(staking.totalWeightedStake(), 0);
    }

    function test_unstakeLockedAfterExpiry() public {
        vm.prank(alice);
        uint256 id = staking.stake(STAKE_AMT, 30);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        staking.unstake(id);

        assertFalse(staking.getStake(id).active);
    }

    function test_revert_unstakeLockedBeforeExpiry() public {
        vm.prank(alice);
        uint256 id = staking.stake(STAKE_AMT, 30);

        vm.prank(alice);
        vm.expectRevert();
        staking.unstake(id);
    }

    function test_revert_unstakeNotOwner() public {
        uint256 id = _stakeDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.NotStakeOwner.selector, id));
        staking.unstake(id);
    }

    function test_revert_unstakeInactive() public {
        uint256 id = _stakeDefault();

        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        staking.unstake(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.StakeNotActive.selector, id));
        staking.unstake(id);
    }

    // ─── Revenue + Rewards ──────────────────────────────────────────────

    function test_distributeRevenue() public {
        _stakeDefault(); // alice stakes 1000 NEXUS
        _addRevenue(10 ether);

        uint256 treasuryBefore = treasury.balance;
        staking.distributeRevenue();

        // 50% to stakers, 50% to treasury
        assertEq(treasury.balance - treasuryBefore, 5 ether);
        assertEq(staking.pendingRevenue(), 0);
    }

    function test_claimRewards() public {
        _stakeDefault();
        _addRevenue(10 ether);
        staking.distributeRevenue();

        uint256 pending = staking.getPendingRewards(0);
        assertEq(pending, 5 ether); // alice gets 100% of staker share

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        staking.claimRewards(0);

        assertEq(alice.balance - balBefore, 5 ether);
    }

    function test_unstakeWithRewards() public {
        _stakeDefault();
        _addRevenue(4 ether);
        staking.distributeRevenue();

        vm.warp(block.timestamp + 8 days);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        staking.unstake(0);

        assertEq(alice.balance - balBefore, 2 ether); // 50% of 4 ETH
    }

    function test_proportionalRewards() public {
        // alice stakes 1000 (1x), bob stakes 1000 (3x with 365-day lock)
        vm.prank(alice);
        staking.stake(STAKE_AMT, 7); // weight = 1000
        vm.prank(bob);
        staking.stake(STAKE_AMT, 365); // weight = 3000

        // total weighted = 4000
        _addRevenue(8 ether);
        staking.distributeRevenue(); // 4 ETH to stakers

        uint256 alicePending = staking.getPendingRewards(0);
        uint256 bobPending = staking.getPendingRewards(1);

        // alice: 1000/4000 * 4 ETH = 1 ETH
        // bob: 3000/4000 * 4 ETH = 3 ETH
        assertEq(alicePending, 1 ether);
        assertEq(bobPending, 3 ether);
    }

    function test_multipleDistributions() public {
        _stakeDefault();

        _addRevenue(2 ether);
        staking.distributeRevenue();

        _addRevenue(4 ether);
        staking.distributeRevenue();

        uint256 pending = staking.getPendingRewards(0);
        assertEq(pending, 3 ether); // 1 + 2 (50% of each)
    }

    function test_revert_distributeNoRevenue() public {
        _stakeDefault();
        vm.expectRevert(IAgentStaking.NoRevenue.selector);
        staking.distributeRevenue();
    }

    function test_revert_distributeNoStakers() public {
        _addRevenue(1 ether);
        vm.expectRevert(IAgentStaking.NoRevenue.selector);
        staking.distributeRevenue();
    }

    function test_revert_claimNothing() public {
        _stakeDefault();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.NothingToClaim.selector, 0));
        staking.claimRewards(0);
    }

    // ─── Revenue Input ──────────────────────────────────────────────────

    function test_addRevenueFromProtocol() public {
        _addRevenue(5 ether);
        assertEq(staking.pendingRevenue(), 5 ether);
    }

    function test_addRevenueViaReceive() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(staking.pendingRevenue(), 1 ether);
    }

    function test_revert_addRevenueUnauthorized() public {
        address rando = makeAddr("rando");
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.NotAuthorizedProtocol.selector, rando));
        staking.addRevenue{value: 1 ether}();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizeProtocol() public {
        address p2 = makeAddr("p2");
        vm.prank(owner);
        staking.authorizeProtocol(p2);
        assertTrue(staking.isAuthorizedProtocol(p2));
    }

    function test_revokeProtocol() public {
        vm.prank(owner);
        staking.revokeProtocol(protocol1);
        assertFalse(staking.isAuthorizedProtocol(protocol1));
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        staking.setTreasury(newT);
        assertEq(staking.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentStaking.ZeroAddress.selector);
        staking.setTreasury(address(0));
    }

    function test_revert_getStakeNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentStaking.StakeNotFound.selector, 999));
        staking.getStake(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_stakeAndUnstake(uint256 amount) public {
        amount = bound(amount, 1e18, 50_000e18);

        vm.prank(alice);
        uint256 id = staking.stake(amount, 7);

        vm.warp(block.timestamp + 8 days);

        uint256 balBefore = nexus.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(id);

        assertEq(nexus.balanceOf(alice) - balBefore, amount);
    }

    function testFuzz_rewardDistribution(uint256 revenue) public {
        revenue = bound(revenue, 0.01 ether, 100 ether);
        _stakeDefault();

        vm.deal(protocol1, revenue);
        vm.prank(protocol1);
        staking.addRevenue{value: revenue}();

        staking.distributeRevenue();

        uint256 pending = staking.getPendingRewards(0);
        assertApproxEqAbs(pending, revenue / 2, 1000); // 50% to staker (small rounding)
    }

    function testFuzz_boostMultiplier(uint256 amount) public {
        amount = bound(amount, 1e18, 50_000e18);

        vm.prank(alice);
        uint256 id = staking.stake(amount, 365);

        IAgentStaking.StakeInfo memory s = staking.getStake(id);
        assertEq(s.weightedAmount, amount * 30000 / 10000);
    }
}
