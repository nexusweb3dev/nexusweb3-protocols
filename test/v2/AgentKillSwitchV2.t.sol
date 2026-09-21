// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AgentKillSwitchV2} from "../../src/v2/AgentKillSwitchV2.sol";
import {IAgentKillSwitchV2} from "../../src/v2/interfaces/IAgentKillSwitchV2.sol";

contract AgentKillSwitchV2Test is Test {
    AgentKillSwitchV2 ks;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address guardian = makeAddr("guardian");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    address protocol = makeAddr("protocol");

    uint128 constant SPEND_LIMIT = 1_000_000_000; // $1000 USDC
    uint32 constant TX_LIMIT = 10;
    uint48 constant SESSION = 1 hours;

    function setUp() public {
        vm.warp(1_000_000);
        ks = new AgentKillSwitchV2(owner);
        vm.prank(owner);
        ks.authorizeProtocol(protocol);
    }

    function _register() internal {
        vm.prank(agent);
        ks.register(SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    function _withGuardian() internal {
        _register();
        vm.prank(agent);
        ks.setGuardian(guardian);
    }

    function _consume(uint256 amount) internal {
        vm.prank(protocol);
        ks.consume(agent, amount);
    }

    // ─── Constructor / admin ────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(ks.owner(), owner);
        assertTrue(ks.isAuthorizedProtocol(protocol));
        assertEq(ks.MIN_SESSION_DURATION(), 1 hours);
        assertEq(ks.MAX_SESSION_DURATION(), 365 days);
    }

    function test_revert_constructorZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AgentKillSwitchV2(address(0));
    }

    function test_authorizeProtocol() public {
        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.ProtocolAuthorized(stranger);
        vm.prank(owner);
        ks.authorizeProtocol(stranger);
        assertTrue(ks.isAuthorizedProtocol(stranger));
    }

    function test_revert_authorizeTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AlreadyAuthorized.selector, protocol));
        ks.authorizeProtocol(protocol);
    }

    function test_revert_authorizeZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAgentKillSwitchV2.ZeroAddress.selector);
        ks.authorizeProtocol(address(0));
    }

    function test_revert_authorizeNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        ks.authorizeProtocol(stranger);
    }

    function test_revokeProtocol() public {
        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.ProtocolRevoked(protocol);
        vm.prank(owner);
        ks.revokeProtocol(protocol);
        assertFalse(ks.isAuthorizedProtocol(protocol));
    }

    function test_revert_revokeUnauthorized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotAuthorized.selector, stranger));
        ks.revokeProtocol(stranger);
    }

    function test_revert_revokeNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        ks.revokeProtocol(protocol);
    }

    // ─── Register ───────────────────────────────────────────────────────

    function test_register() public {
        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.AgentRegistered(agent, SPEND_LIMIT, TX_LIMIT, SESSION);
        _register();

        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(agent);
        assertEq(c.spendingLimit, SPEND_LIMIT);
        assertEq(c.spent, 0);
        assertEq(c.txLimit, TX_LIMIT);
        assertEq(c.txCount, 0);
        assertEq(c.sessionDuration, SESSION);
        assertEq(c.sessionStart, uint48(block.timestamp));
        assertTrue(c.registered);
        assertFalse(c.killed);
        assertFalse(c.paused);
    }

    function test_revert_registerTwice() public {
        _register();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AlreadyRegistered.selector, agent));
        ks.register(SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    function test_revert_registerDurationTooShort() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.InvalidSessionDuration.selector, uint48(1 hours - 1)));
        ks.register(SPEND_LIMIT, TX_LIMIT, uint48(1 hours - 1));
    }

    function test_revert_registerDurationTooLong() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitchV2.InvalidSessionDuration.selector, uint48(365 days + 1))
        );
        ks.register(SPEND_LIMIT, TX_LIMIT, uint48(365 days + 1));
    }

    function test_registerAtDurationBounds() public {
        vm.prank(agent);
        ks.register(SPEND_LIMIT, TX_LIMIT, 1 hours);
        vm.prank(stranger);
        ks.register(SPEND_LIMIT, TX_LIMIT, 365 days);
        assertEq(ks.getConfig(stranger).sessionDuration, 365 days);
    }

    // ─── setLimits ──────────────────────────────────────────────────────

    function test_setLimits() public {
        _register();
        _consume(100);

        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.LimitsUpdated(agent, 5, 2, 2 hours);
        vm.prank(agent);
        ks.setLimits(5, 2, 2 hours);

        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(agent);
        assertEq(c.spendingLimit, 5);
        assertEq(c.txLimit, 2);
        assertEq(c.sessionDuration, 2 hours);
        assertEq(c.spent, 100, "counters must not reset");
        assertEq(c.txCount, 1, "counters must not reset");
    }

    function test_revert_setLimitsNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.setLimits(1, 1, SESSION);
    }

    function test_revert_setLimitsBadDuration() public {
        _register();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.InvalidSessionDuration.selector, uint48(0)));
        ks.setLimits(1, 1, 0);
    }

    function test_revert_setLimitsByGuardian() public {
        _withGuardian();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, guardian));
        ks.setLimits(type(uint128).max, 0, SESSION);
    }

    function test_revert_setLimitsByOperator() public {
        _register();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, operator));
        ks.setLimits(type(uint128).max, 0, SESSION);
    }

    // ─── Guardian ───────────────────────────────────────────────────────

    function test_setGuardian() public {
        _register();
        vm.expectEmit(true, true, false, false);
        emit IAgentKillSwitchV2.GuardianSet(agent, guardian);
        vm.prank(agent);
        ks.setGuardian(guardian);
        assertEq(ks.guardianOf(agent), guardian);
    }

    function test_clearGuardian() public {
        _withGuardian();
        vm.prank(agent);
        ks.setGuardian(address(0));
        assertEq(ks.guardianOf(agent), address(0));
    }

    function test_revert_setGuardianNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.setGuardian(guardian);
    }

    // ─── Kill / resume ──────────────────────────────────────────────────

    function test_killByPrincipal() public {
        _register();
        vm.expectEmit(true, true, false, false);
        emit IAgentKillSwitchV2.AgentKilled(agent, agent);
        vm.prank(agent);
        ks.kill(agent);
        assertFalse(ks.isActive(agent));
    }

    function test_killByGuardian() public {
        _withGuardian();
        vm.prank(guardian);
        ks.kill(agent);
        assertTrue(ks.getConfig(agent).killed);
    }

    function test_revert_killByOperator() public {
        _withGuardian();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipalOrGuardian.selector, agent, operator));
        ks.kill(agent);
    }

    function test_revert_killTwice() public {
        _register();
        vm.startPrank(agent);
        ks.kill(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, agent));
        ks.kill(agent);
        vm.stopPrank();
    }

    function test_revert_killNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.kill(agent);
    }

    function test_resume() public {
        _register();
        vm.startPrank(agent);
        ks.kill(agent);
        vm.expectEmit(true, false, false, false);
        emit IAgentKillSwitchV2.AgentResumed(agent);
        ks.resume();
        vm.stopPrank();
        assertTrue(ks.isActive(agent));
        _consume(1);
    }

    function test_revert_resumeNotKilled() public {
        _register();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotKilled.selector, agent));
        ks.resume();
    }

    function test_revert_resumeNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.resume();
    }

    function test_revert_resumeByGuardian() public {
        _withGuardian();
        vm.prank(agent);
        ks.kill(agent);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, guardian));
        ks.resume();
        assertTrue(ks.getConfig(agent).killed);
    }

    // ─── Pause / unpause ────────────────────────────────────────────────

    function test_pauseAndUnpauseByGuardian() public {
        _withGuardian();
        vm.expectEmit(true, true, false, false);
        emit IAgentKillSwitchV2.AgentPaused(agent, guardian);
        vm.prank(guardian);
        ks.pause(agent);
        assertFalse(ks.isActive(agent));

        vm.expectEmit(true, true, false, false);
        emit IAgentKillSwitchV2.AgentUnpaused(agent, guardian);
        vm.prank(guardian);
        ks.unpause(agent);
        assertTrue(ks.isActive(agent));
    }

    function test_revert_pauseTwice() public {
        _register();
        vm.startPrank(agent);
        ks.pause(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsPaused.selector, agent));
        ks.pause(agent);
        vm.stopPrank();
    }

    function test_revert_unpauseNotPaused() public {
        _register();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPaused.selector, agent));
        ks.unpause(agent);
    }

    function test_revert_pauseByOperator() public {
        _register();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipalOrGuardian.selector, agent, operator));
        ks.pause(agent);
    }

    function test_revert_unpauseByOperator() public {
        _register();
        vm.prank(agent);
        ks.pause(agent);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipalOrGuardian.selector, agent, operator));
        ks.unpause(agent);
    }

    function test_revert_pauseNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.pause(agent);
    }

    // ─── resetSession ───────────────────────────────────────────────────

    function test_resetSessionByPrincipal() public {
        _register();
        _consume(500);
        vm.warp(block.timestamp + 10 minutes);

        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.SessionReset(agent, uint48(block.timestamp));
        vm.prank(agent);
        ks.resetSession(agent);

        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(agent);
        assertEq(c.spent, 0);
        assertEq(c.txCount, 0);
        assertEq(c.sessionStart, uint48(block.timestamp));
    }

    function test_resetSessionByGuardian() public {
        _withGuardian();
        _consume(500);
        vm.prank(guardian);
        ks.resetSession(agent);
        assertEq(ks.getConfig(agent).spent, 0);
    }

    function test_revert_resetSessionByOperator() public {
        _register();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipalOrGuardian.selector, agent, operator));
        ks.resetSession(agent);
    }

    function test_revert_resetSessionNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, agent));
        ks.resetSession(agent);
    }

    // ─── consume ────────────────────────────────────────────────────────

    function test_consume() public {
        _register();
        vm.expectEmit(true, true, false, true);
        emit IAgentKillSwitchV2.SpendConsumed(agent, protocol, 250);
        _consume(250);

        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(agent);
        assertEq(c.spent, 250);
        assertEq(c.txCount, 1);
        assertEq(ks.remainingSpend(agent), SPEND_LIMIT - 250);
    }

    function test_consumeZeroAmountCountsAsTx() public {
        _register();
        _consume(0);
        assertEq(ks.getConfig(agent).txCount, 1);
        assertEq(ks.getConfig(agent).spent, 0);
    }

    function test_consumeUnregisteredIsSilentNoOp() public {
        vm.recordLogs();
        _consume(type(uint128).max);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(ks.getConfig(agent).registered);
    }

    function test_revert_consumeNotAuthorizedProtocol() public {
        _register();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotAuthorizedProtocol.selector, stranger));
        ks.consume(agent, 1);
    }

    function test_revert_consumeAfterRevoke() public {
        _register();
        vm.prank(owner);
        ks.revokeProtocol(protocol);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotAuthorizedProtocol.selector, protocol));
        ks.consume(agent, 1);
    }

    function test_revert_consumeWhenKilled() public {
        _register();
        vm.prank(agent);
        ks.kill(agent);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, agent));
        ks.consume(agent, 1);
    }

    function test_revert_consumeWhenPaused() public {
        _register();
        vm.prank(agent);
        ks.pause(agent);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsPaused.selector, agent));
        ks.consume(agent, 1);
    }

    function test_consumeExactLimitThenOneMoreFails() public {
        _register();
        _consume(SPEND_LIMIT);
        assertEq(ks.remainingSpend(agent), 0);

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, agent, 1, 0));
        ks.consume(agent, 1);
    }

    function test_revert_consumeOverSpendingLimit() public {
        _register();
        _consume(SPEND_LIMIT - 10);
        vm.prank(protocol);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, agent, 11, uint256(10))
        );
        ks.consume(agent, 11);
    }

    function test_revert_consumeOverTxLimit() public {
        _register();
        for (uint256 i; i < TX_LIMIT; ++i) {
            _consume(1);
        }
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.TxLimitExceeded.selector, agent, TX_LIMIT));
        ks.consume(agent, 1);
    }

    function test_txLimitZeroIsUnlimited() public {
        vm.prank(agent);
        ks.register(SPEND_LIMIT, 0, SESSION);
        for (uint256 i; i < 50; ++i) {
            _consume(1);
        }
        assertEq(ks.getConfig(agent).txCount, 50);
    }

    // ─── Session auto-roll ──────────────────────────────────────────────

    function test_consumeRollsExpiredSession() public {
        _register();
        _consume(SPEND_LIMIT);

        uint48 newStart = uint48(block.timestamp) + SESSION;
        vm.warp(newStart);

        vm.expectEmit(true, false, false, true);
        emit IAgentKillSwitchV2.SessionReset(agent, newStart);
        vm.expectEmit(true, true, false, true);
        emit IAgentKillSwitchV2.SpendConsumed(agent, protocol, 700);
        _consume(700);

        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(agent);
        assertEq(c.spent, 700);
        assertEq(c.txCount, 1);
        assertEq(c.sessionStart, newStart);
    }

    function test_consumeDoesNotRollOneSecondBeforeExpiry() public {
        _register();
        _consume(SPEND_LIMIT);
        vm.warp(block.timestamp + SESSION - 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, agent, 1, 0));
        ks.consume(agent, 1);
    }

    function test_expiredSessionRollAlsoResetsTxCount() public {
        _register();
        for (uint256 i; i < TX_LIMIT; ++i) {
            _consume(1);
        }
        vm.warp(block.timestamp + SESSION);
        _consume(1);
        assertEq(ks.getConfig(agent).txCount, 1);
    }

    function test_killSurvivesSessionRoll() public {
        _register();
        vm.prank(agent);
        ks.kill(agent);
        vm.warp(block.timestamp + SESSION * 5);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, agent));
        ks.consume(agent, 1);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function test_isActiveUnregisteredIsTrue() public view {
        assertTrue(ks.isActive(stranger));
    }

    function test_remainingSpendUnregisteredIsMax() public view {
        assertEq(ks.remainingSpend(stranger), type(uint256).max);
    }

    function test_remainingSpendAcrossExpiredSession() public {
        _register();
        _consume(SPEND_LIMIT - 1);
        assertEq(ks.remainingSpend(agent), 1);
        vm.warp(block.timestamp + SESSION);
        assertEq(ks.remainingSpend(agent), SPEND_LIMIT);
    }

    function test_getConfigUnregisteredIsEmpty() public view {
        IAgentKillSwitchV2.AgentConfig memory c = ks.getConfig(stranger);
        assertFalse(c.registered);
        assertEq(c.spendingLimit, 0);
        assertEq(c.sessionStart, 0);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_consumeRespectsSpendingLimit(uint128 limit, uint128 amount) public {
        vm.prank(agent);
        ks.register(limit, 0, SESSION);

        vm.prank(protocol);
        if (amount > limit) {
            vm.expectRevert(
                abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, agent, amount, uint256(limit))
            );
            ks.consume(agent, amount);
            assertEq(ks.getConfig(agent).spent, 0);
        } else {
            ks.consume(agent, amount);
            assertEq(ks.getConfig(agent).spent, amount);
            assertEq(ks.remainingSpend(agent), uint256(limit) - amount);
        }
    }

    function testFuzz_sessionDurationBounds(uint48 duration) public {
        vm.prank(agent);
        if (duration < 1 hours || duration > 365 days) {
            vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.InvalidSessionDuration.selector, duration));
            ks.register(SPEND_LIMIT, TX_LIMIT, duration);
            assertFalse(ks.getConfig(agent).registered);
        } else {
            ks.register(SPEND_LIMIT, TX_LIMIT, duration);
            assertEq(ks.getConfig(agent).sessionDuration, duration);
        }
    }

    function testFuzz_consumeSequenceNeverExceedsLimit(uint64[8] memory amounts) public {
        _register();
        uint256 expected;

        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            vm.prank(protocol);
            if (expected + amount > SPEND_LIMIT) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAgentKillSwitchV2.SpendingLimitExceeded.selector, agent, amount, SPEND_LIMIT - expected
                    )
                );
                ks.consume(agent, amount);
            } else {
                ks.consume(agent, amount);
                expected += amount;
            }
            assertEq(ks.getConfig(agent).spent, expected);
            assertLe(ks.getConfig(agent).spent, SPEND_LIMIT);
        }
    }

    function testFuzz_onlyPrincipalOrGuardianCanKill(address caller) public {
        _withGuardian();
        vm.assume(caller != agent && caller != guardian);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipalOrGuardian.selector, agent, caller));
        ks.kill(agent);
    }
}
