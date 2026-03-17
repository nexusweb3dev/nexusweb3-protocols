// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentScheduler} from "../src/AgentScheduler.sol";
import {IAgentScheduler} from "../src/interfaces/IAgentScheduler.sol";

contract AgentSchedulerTest is Test {
    AgentScheduler scheduler;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address keeper = makeAddr("keeper");

    uint256 constant SCHED_FEE = 0.001 ether;
    uint256 constant KEEPER_REWARD = 0.0001 ether;

    function setUp() public {
        scheduler = new AgentScheduler(treasury, owner, SCHED_FEE, KEEPER_REWARD);
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(keeper, 1 ether);
    }

    function _futureTime() internal view returns (uint48) {
        return uint48(block.timestamp + 1 hours);
    }

    function _scheduleDefault() internal returns (uint256) {
        vm.prank(agent1);
        return scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD}(
            "callSomeFunction()", _futureTime(), 0, 1
        );
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(scheduler.treasury(), treasury);
        assertEq(scheduler.owner(), owner);
        assertEq(scheduler.schedulingFee(), SCHED_FEE);
        assertEq(scheduler.keeperReward(), KEEPER_REWARD);
        assertEq(scheduler.taskCount(), 0);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentScheduler.ZeroAddress.selector);
        new AgentScheduler(address(0), owner, SCHED_FEE, KEEPER_REWARD);
    }

    // ─── Schedule ───────────────────────────────────────────────────────

    function test_scheduleTask() public {
        uint256 id = _scheduleDefault();

        assertEq(id, 0);
        assertEq(scheduler.taskCount(), 1);
        assertEq(scheduler.getOwnerTaskCount(agent1), 1);

        IAgentScheduler.Task memory t = scheduler.getTask(id);
        assertEq(t.owner, agent1);
        assertEq(t.executeAfter, _futureTime());
        assertEq(t.repeatInterval, 0);
        assertEq(t.maxExecutions, 1);
        assertEq(t.executionCount, 0);
        assertEq(t.keeperBalance, KEEPER_REWARD);
        assertTrue(t.active);
    }

    function test_scheduleRepeatingTask() public {
        uint256 maxExec = 5;
        uint256 totalFee = SCHED_FEE + KEEPER_REWARD * maxExec;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: totalFee}(
            "repeat()", _futureTime(), uint48(1 hours), maxExec
        );

        IAgentScheduler.Task memory t = scheduler.getTask(id);
        assertEq(t.repeatInterval, uint48(1 hours));
        assertEq(t.maxExecutions, maxExec);
        assertEq(t.keeperBalance, KEEPER_REWARD * maxExec);
    }

    function test_scheduleCollectsFee() public {
        _scheduleDefault();
        assertEq(scheduler.accumulatedFees(), SCHED_FEE);
    }

    function test_scheduleRefundsOverpayment() public {
        uint256 balBefore = agent1.balance;

        vm.prank(agent1);
        scheduler.scheduleTask{value: 1 ether}("task()", _futureTime(), 0, 1);

        uint256 expected = SCHED_FEE + KEEPER_REWARD;
        assertEq(balBefore - agent1.balance, expected);
    }

    function test_revert_scheduleEmptyData() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentScheduler.EmptyTaskData.selector);
        scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD}("", _futureTime(), 0, 1);
    }

    function test_revert_schedulePastTimestamp() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentScheduler.InvalidExecuteAfter.selector);
        scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD}(
            "task()", uint48(block.timestamp), 0, 1
        );
    }

    function test_revert_scheduleZeroExecutions() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentScheduler.InvalidMaxExecutions.selector);
        scheduler.scheduleTask{value: SCHED_FEE}("task()", _futureTime(), 0, 0);
    }

    function test_revert_scheduleInsufficientFee() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            IAgentScheduler.InsufficientFee.selector, SCHED_FEE + KEEPER_REWARD, 0
        ));
        scheduler.scheduleTask("task()", _futureTime(), 0, 1);
    }

    function test_revert_scheduleMaxTasks() public {
        uint256 fee = SCHED_FEE + KEEPER_REWARD;
        vm.startPrank(agent1);
        for (uint i; i < 100; i++) {
            scheduler.scheduleTask{value: fee}(
                "t()", uint48(block.timestamp + 1 hours + i), 0, 1
            );
        }
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.MaxTasksPerOwner.selector, agent1));
        scheduler.scheduleTask{value: fee}("overflow()", _futureTime(), 0, 1);
        vm.stopPrank();
    }

    function test_revert_scheduleWhenPaused() public {
        vm.prank(owner);
        scheduler.pause();

        vm.prank(agent1);
        vm.expectRevert();
        scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD}("task()", _futureTime(), 0, 1);
    }

    function test_revert_scheduleIntervalTooShort() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentScheduler.InvalidExecuteAfter.selector);
        scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD * 3}(
            "task()", _futureTime(), uint48(1 minutes), 3
        );
    }

    // ─── Execute ────────────────────────────────────────────────────────

    function test_executeTask() public {
        uint256 id = _scheduleDefault();

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        scheduler.executeTask(id);

        assertEq(keeper.balance - keeperBefore, KEEPER_REWARD);

        IAgentScheduler.Task memory t = scheduler.getTask(id);
        assertEq(t.executionCount, 1);
        assertFalse(t.active); // one-time, now done
    }

    function test_executeRepeatingTask() public {
        uint256 maxExec = 3;
        uint256 fee = SCHED_FEE + KEEPER_REWARD * maxExec;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: fee}(
            "repeat()", _futureTime(), uint48(1 hours), maxExec
        );

        // execute first
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        scheduler.executeTask(id);

        IAgentScheduler.Task memory t = scheduler.getTask(id);
        assertEq(t.executionCount, 1);
        assertTrue(t.active); // still active, 2 more to go

        // execute second
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        scheduler.executeTask(id);

        t = scheduler.getTask(id);
        assertEq(t.executionCount, 2);
        assertTrue(t.active);

        // execute third (final)
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        scheduler.executeTask(id);

        t = scheduler.getTask(id);
        assertEq(t.executionCount, 3);
        assertFalse(t.active); // done
    }

    function test_revert_executeNotReady() public {
        uint256 id = _scheduleDefault();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(
            IAgentScheduler.TaskNotReady.selector, id, _futureTime()
        ));
        scheduler.executeTask(id);
    }

    function test_revert_executeInactive() public {
        uint256 id = _scheduleDefault();

        vm.prank(agent1);
        scheduler.cancelTask(id);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.TaskNotActive.selector, id));
        scheduler.executeTask(id);
    }

    function test_revert_executeMaxReached() public {
        uint256 id = _scheduleDefault();

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        scheduler.executeTask(id);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.TaskNotActive.selector, id));
        scheduler.executeTask(id);
    }

    function test_isTaskReady() public {
        uint256 id = _scheduleDefault();

        assertFalse(scheduler.isTaskReady(id));

        vm.warp(block.timestamp + 1 hours);
        assertTrue(scheduler.isTaskReady(id));
    }

    function test_anyoneCanExecute() public {
        uint256 id = _scheduleDefault();
        vm.warp(block.timestamp + 1 hours + 1);

        // agent2 (a stranger) can execute and earn reward
        uint256 before2 = agent2.balance;
        vm.prank(agent2);
        scheduler.executeTask(id);
        assertEq(agent2.balance - before2, KEEPER_REWARD);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    function test_cancelTask() public {
        uint256 id = _scheduleDefault();

        uint256 balBefore = agent1.balance;
        vm.prank(agent1);
        scheduler.cancelTask(id);

        assertFalse(scheduler.getTask(id).active);
        assertEq(agent1.balance - balBefore, KEEPER_REWARD); // refund
        assertEq(scheduler.getOwnerTaskCount(agent1), 0);
    }

    function test_cancelPartiallyExecuted() public {
        uint256 maxExec = 3;
        uint256 fee = SCHED_FEE + KEEPER_REWARD * maxExec;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: fee}(
            "r()", _futureTime(), uint48(1 hours), maxExec
        );

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        scheduler.executeTask(id);

        // cancel after 1 of 3 executions — refund 2 keeper rewards
        uint256 balBefore = agent1.balance;
        vm.prank(agent1);
        scheduler.cancelTask(id);

        assertEq(agent1.balance - balBefore, KEEPER_REWARD * 2);
    }

    function test_revert_cancelNotOwner() public {
        uint256 id = _scheduleDefault();

        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.NotTaskOwner.selector, id));
        scheduler.cancelTask(id);
    }

    function test_revert_cancelInactive() public {
        uint256 id = _scheduleDefault();

        vm.prank(agent1);
        scheduler.cancelTask(id);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.TaskNotActive.selector, id));
        scheduler.cancelTask(id);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _scheduleDefault();

        uint256 treasuryBefore = treasury.balance;
        scheduler.collectFees();

        assertEq(treasury.balance - treasuryBefore, SCHED_FEE);
        assertEq(scheduler.accumulatedFees(), 0);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentScheduler.NoFeesToCollect.selector);
        scheduler.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setSchedulingFee() public {
        vm.prank(owner);
        scheduler.setSchedulingFee(0.002 ether);
        assertEq(scheduler.schedulingFee(), 0.002 ether);
    }

    function test_setKeeperReward() public {
        vm.prank(owner);
        scheduler.setKeeperReward(0.0005 ether);
        assertEq(scheduler.keeperReward(), 0.0005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        scheduler.setTreasury(newT);
        assertEq(scheduler.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentScheduler.ZeroAddress.selector);
        scheduler.setTreasury(address(0));
    }

    function test_revert_getTaskNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentScheduler.TaskNotFound.selector, 999));
        scheduler.getTask(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_scheduleAndExecute(uint48 delay) public {
        delay = uint48(bound(delay, 1 hours, 30 days));

        uint48 execAt = uint48(block.timestamp) + delay;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: SCHED_FEE + KEEPER_REWARD}(
            "fuzz()", execAt, 0, 1
        );

        vm.warp(execAt + 1);
        uint256 keeperBal = keeper.balance;

        vm.prank(keeper);
        scheduler.executeTask(id);

        assertEq(keeper.balance - keeperBal, KEEPER_REWARD);
        assertFalse(scheduler.getTask(id).active);
    }

    function testFuzz_cancelRefundsCorrectly(uint256 maxExec) public {
        maxExec = bound(maxExec, 1, 20);
        uint256 deposit = KEEPER_REWARD * maxExec;
        uint256 fee = SCHED_FEE + deposit;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: fee}(
            "fuzz()", _futureTime(), 0, maxExec
        );

        uint256 balBefore = agent1.balance;
        vm.prank(agent1);
        scheduler.cancelTask(id);

        assertEq(agent1.balance - balBefore, deposit);
    }

    function testFuzz_repeatingExecution(uint256 repeats) public {
        repeats = bound(repeats, 2, 10);
        uint256 fee = SCHED_FEE + KEEPER_REWARD * repeats;

        vm.prank(agent1);
        uint256 id = scheduler.scheduleTask{value: fee}(
            "r()", _futureTime(), uint48(1 hours), repeats
        );

        for (uint i; i < repeats; i++) {
            vm.warp(block.timestamp + 1 hours + 1);
            vm.prank(keeper);
            scheduler.executeTask(id);
        }

        IAgentScheduler.Task memory t = scheduler.getTask(id);
        assertEq(t.executionCount, repeats);
        assertFalse(t.active);
    }
}
