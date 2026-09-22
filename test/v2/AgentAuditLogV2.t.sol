// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {AgentAuditLogV2} from "../../src/v2/AgentAuditLogV2.sol";
import {OperatorGated} from "../../src/v2/OperatorGated.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentAuditLogV2} from "../../src/v2/interfaces/IAgentAuditLogV2.sol";

contract AgentAuditLogV2Test is Test {
    AgentAccess access;
    AgentAuditLogV2 auditLog;

    address owner = makeAddr("owner");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address operator1 = makeAddr("operator1");
    address protocol = makeAddr("protocol");
    address stranger = makeAddr("stranger");

    bytes32 constant TRANSFER = keccak256("TRANSFER");
    bytes32 constant VOTE = keccak256("VOTE");
    bytes32 constant DATA_HASH = keccak256("some-data");

    uint48 constant FOREVER = type(uint48).max;

    function setUp() public {
        access = new AgentAccess();
        auditLog = new AgentAuditLogV2(IAgentAccess(address(access)), owner);

        vm.prank(agent1);
        access.authorizeOperator(operator1, FOREVER);

        vm.prank(owner);
        auditLog.authorizeProtocol(protocol);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _batch(uint256 n)
        internal
        pure
        returns (bytes32[] memory types_, bytes32[] memory hashes, uint256[] memory values)
    {
        types_ = new bytes32[](n);
        hashes = new bytes32[](n);
        values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            types_[i] = keccak256(abi.encode("type", i));
            hashes[i] = keccak256(abi.encode("hash", i));
            values[i] = i + 1;
        }
    }

    function _logN(address agent, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(agent);
            auditLog.log(agent, TRANSFER, keccak256(abi.encode(agent, i)), i);
        }
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(auditLog.access()), address(access));
        assertEq(auditLog.owner(), owner);
        assertEq(auditLog.totalLogs(), 0);
        assertEq(auditLog.MAX_BATCH_SIZE(), 50);
        assertFalse(auditLog.paused());
    }

    function test_revert_constructorZeroAccess() public {
        vm.expectRevert(OperatorGated.ZeroAccess.selector);
        new AgentAuditLogV2(IAgentAccess(address(0)), owner);
    }

    // ─── log: caller classes ────────────────────────────────────────────

    function test_logByAgent() public {
        vm.prank(agent1);
        uint256 id = auditLog.log(agent1, TRANSFER, DATA_HASH, 100);

        assertEq(id, 0);
        assertEq(auditLog.totalLogs(), 1);
        assertEq(auditLog.getLogCount(agent1), 1);

        IAgentAuditLogV2.ActionLog memory l = auditLog.getLog(id);
        assertEq(l.agent, agent1);
        assertEq(l.caller, agent1);
        assertEq(l.actionType, TRANSFER);
        assertEq(l.dataHash, DATA_HASH);
        assertEq(l.value, 100);
        assertEq(l.timestamp, uint48(block.timestamp));
        assertEq(l.blockNumber, uint64(block.number));
    }

    function test_logByOperator() public {
        vm.prank(operator1);
        uint256 id = auditLog.log(agent1, VOTE, DATA_HASH, 7);

        IAgentAuditLogV2.ActionLog memory l = auditLog.getLog(id);
        assertEq(l.agent, agent1);
        assertEq(l.caller, operator1);
        assertEq(auditLog.getLogCount(agent1), 1);
    }

    function test_logByProtocolForAnyAgent() public {
        vm.prank(protocol);
        auditLog.log(agent2, TRANSFER, DATA_HASH, 1);

        IAgentAuditLogV2.ActionLog memory l = auditLog.getLog(0);
        assertEq(l.agent, agent2);
        assertEq(l.caller, protocol);
        assertEq(auditLog.getLogCount(agent2), 1);
        assertEq(auditLog.getLogCount(agent1), 0);
    }

    function test_logEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(auditLog));
        emit IAgentAuditLogV2.ActionLogged(0, agent1, TRANSFER, agent1, DATA_HASH, 42);
        vm.prank(agent1);
        auditLog.log(agent1, TRANSFER, DATA_HASH, 42);
    }

    function test_logIdsIncrementGlobally() public {
        vm.prank(agent1);
        assertEq(auditLog.log(agent1, TRANSFER, DATA_HASH, 0), 0);
        vm.prank(agent2);
        assertEq(auditLog.log(agent2, TRANSFER, DATA_HASH, 0), 1);
        vm.prank(agent1);
        assertEq(auditLog.log(agent1, TRANSFER, DATA_HASH, 0), 2);
        assertEq(auditLog.totalLogs(), 3);
    }

    // ─── log: reverts ───────────────────────────────────────────────────

    function test_revert_logByStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, agent1, stranger));
        auditLog.log(agent1, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logByExpiredOperator() public {
        address tempOp = makeAddr("tempOp");
        vm.prank(agent1);
        access.authorizeOperator(tempOp, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 2 days);
        vm.prank(tempOp);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, agent1, tempOp));
        auditLog.log(agent1, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logByOperatorOfOtherAgent() public {
        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, agent2, operator1));
        auditLog.log(agent2, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logByRevokedProtocol() public {
        vm.prank(owner);
        auditLog.revokeProtocol(protocol);

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, agent2, protocol));
        auditLog.log(agent2, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logZeroAgent() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.ZeroAddress.selector);
        auditLog.log(address(0), TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logZeroActionType() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.InvalidActionType.selector);
        auditLog.log(agent1, bytes32(0), DATA_HASH, 0);
    }

    function test_revert_logZeroDataHash() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.InvalidDataHash.selector);
        auditLog.log(agent1, TRANSFER, bytes32(0), 0);
    }

    // ─── logBatch ───────────────────────────────────────────────────────

    function test_logBatchSingleEntry() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(1);
        vm.prank(agent1);
        uint256 first = auditLog.logBatch(agent1, t, h, v);

        assertEq(first, 0);
        assertEq(auditLog.totalLogs(), 1);
        assertEq(auditLog.getLogCount(agent1), 1);
    }

    function test_logBatchMaxSize() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(50);
        vm.prank(agent1);
        uint256 first = auditLog.logBatch(agent1, t, h, v);

        assertEq(first, 0);
        assertEq(auditLog.totalLogs(), 50);
        assertEq(auditLog.getLogCount(agent1), 50);

        IAgentAuditLogV2.ActionLog memory last = auditLog.getLog(49);
        assertEq(last.actionType, t[49]);
        assertEq(last.dataHash, h[49]);
        assertEq(last.value, v[49]);
    }

    function test_logBatchByOperator() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(3);
        vm.prank(operator1);
        auditLog.logBatch(agent1, t, h, v);

        assertEq(auditLog.getLogCount(agent1), 3);
        assertEq(auditLog.getLog(1).caller, operator1);
    }

    function test_logBatchByProtocol() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(4);
        vm.prank(protocol);
        auditLog.logBatch(agent2, t, h, v);

        assertEq(auditLog.getLogCount(agent2), 4);
        assertEq(auditLog.getLog(3).agent, agent2);
        assertEq(auditLog.getLog(3).caller, protocol);
    }

    function test_logBatchEmitsEventPerEntry() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(3);

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, true, address(auditLog));
            emit IAgentAuditLogV2.ActionLogged(i, agent1, t[i], agent1, h[i], v[i]);
        }
        vm.prank(agent1);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_logBatchContinuesGlobalIds() public {
        vm.prank(agent1);
        auditLog.log(agent1, TRANSFER, DATA_HASH, 0);

        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(2);
        vm.prank(agent1);
        assertEq(auditLog.logBatch(agent1, t, h, v), 1);
        assertEq(auditLog.totalLogs(), 3);
    }

    // ─── logBatch: reverts ──────────────────────────────────────────────

    function test_revert_logBatchTooLarge() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(51);
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.BatchTooLarge.selector, 51));
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchEmpty() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(0);
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.BatchTooLarge.selector, 0));
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchLengthMismatch() public {
        (bytes32[] memory t,, uint256[] memory v) = _batch(3);
        (, bytes32[] memory h,) = _batch(2);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.LengthMismatch.selector);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchValuesLengthMismatch() public {
        (bytes32[] memory t, bytes32[] memory h,) = _batch(3);
        (,, uint256[] memory v) = _batch(2);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.LengthMismatch.selector);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchUnauthorized() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, agent1, stranger));
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchZeroAgent() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(2);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.ZeroAddress.selector);
        auditLog.logBatch(address(0), t, h, v);
    }

    function test_revert_logBatchZeroActionType() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(3);
        t[2] = bytes32(0);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.InvalidActionType.selector);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_revert_logBatchZeroDataHash() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(3);
        h[0] = bytes32(0);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.InvalidDataHash.selector);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_logBatchRevertLeavesNoPartialState() public {
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(3);
        h[2] = bytes32(0);
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLogV2.InvalidDataHash.selector);
        auditLog.logBatch(agent1, t, h, v);

        assertEq(auditLog.totalLogs(), 0);
        assertEq(auditLog.getLogCount(agent1), 0);
    }

    // ─── Views & pagination ─────────────────────────────────────────────

    function test_revert_getLogOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(AgentAuditLogV2.LogNotFound.selector, 0));
        auditLog.getLog(0);
    }

    function test_getAgentLogsFullPage() public {
        _logN(agent1, 5);
        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(agent1, 0, 5);
        assertEq(page.length, 5);
        assertEq(page[0].value, 0);
        assertEq(page[4].value, 4);
    }

    function test_getAgentLogsMiddlePage() public {
        _logN(agent1, 10);
        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(agent1, 3, 4);
        assertEq(page.length, 4);
        assertEq(page[0].value, 3);
        assertEq(page[3].value, 6);
    }

    function test_getAgentLogsLimitLargerThanRemaining() public {
        _logN(agent1, 5);
        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(agent1, 3, 100);
        assertEq(page.length, 2);
        assertEq(page[0].value, 3);
        assertEq(page[1].value, 4);
    }

    /// @notice M-05: an unbounded `limit` must not build an unbounded array. 500 requested over 300
    ///         stored entries returns exactly MAX_PAGE_SIZE.
    function test_M05_getAgentLogsClipsLimitToMaxPageSize() public {
        _logN(agent1, 300);

        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(agent1, 0, 500);

        assertEq(auditLog.MAX_PAGE_SIZE(), 200);
        assertEq(page.length, 200);
        assertEq(page[0].value, 0);
        assertEq(page[199].value, 199);
    }

    /// @notice M-05: the cap applies from any offset, and the rest is reachable by paging.
    function test_M05_pagingPastTheCapReachesEveryEntry() public {
        _logN(agent1, 300);

        IAgentAuditLogV2.ActionLog[] memory second = auditLog.getAgentLogs(agent1, 200, type(uint256).max);
        assertEq(second.length, 100);
        assertEq(second[0].value, 200);
        assertEq(second[99].value, 299);
    }

    /// @notice M-05: requests at or below the cap are untouched.
    function test_M05_limitAtCapIsNotClipped() public {
        _logN(agent1, 250);
        assertEq(auditLog.getAgentLogs(agent1, 0, 200).length, 200);
        assertEq(auditLog.getAgentLogs(agent1, 0, 199).length, 199);
    }

    function test_getAgentLogsOffsetEqualsCount() public {
        _logN(agent1, 3);
        assertEq(auditLog.getAgentLogs(agent1, 3, 10).length, 0);
    }

    function test_getAgentLogsOffsetBeyondCount() public {
        _logN(agent1, 3);
        assertEq(auditLog.getAgentLogs(agent1, 99, 10).length, 0);
    }

    function test_getAgentLogsZeroLimit() public {
        _logN(agent1, 3);
        assertEq(auditLog.getAgentLogs(agent1, 0, 0).length, 0);
    }

    function test_getAgentLogsEmptyAgent() public view {
        assertEq(auditLog.getAgentLogs(agent2, 0, 10).length, 0);
        assertEq(auditLog.getLogCount(agent2), 0);
    }

    function test_interleavedAgentsKeepSeparateOrdering() public {
        vm.prank(agent1);
        auditLog.log(agent1, TRANSFER, keccak256("a1-0"), 10);
        vm.prank(agent2);
        auditLog.log(agent2, TRANSFER, keccak256("a2-0"), 20);
        vm.prank(agent1);
        auditLog.log(agent1, VOTE, keccak256("a1-1"), 11);
        vm.prank(agent2);
        auditLog.log(agent2, VOTE, keccak256("a2-1"), 21);

        assertEq(auditLog.totalLogs(), 4);
        assertEq(auditLog.getLogCount(agent1), 2);
        assertEq(auditLog.getLogCount(agent2), 2);

        IAgentAuditLogV2.ActionLog[] memory a1 = auditLog.getAgentLogs(agent1, 0, 10);
        assertEq(a1[0].value, 10);
        assertEq(a1[1].value, 11);
        assertEq(a1[1].agent, agent1);

        IAgentAuditLogV2.ActionLog[] memory a2 = auditLog.getAgentLogs(agent2, 0, 10);
        assertEq(a2[0].value, 20);
        assertEq(a2[1].value, 21);
        assertEq(a2[1].agent, agent2);
    }

    // ─── Protocol authorization ─────────────────────────────────────────

    function test_authorizeProtocol() public {
        address p2 = makeAddr("p2");
        vm.expectEmit(true, false, false, true, address(auditLog));
        emit IAgentAuditLogV2.ProtocolAuthorized(p2);
        vm.prank(owner);
        auditLog.authorizeProtocol(p2);
        assertTrue(auditLog.isAuthorizedProtocol(p2));
    }

    function test_revokeProtocol() public {
        vm.expectEmit(true, false, false, true, address(auditLog));
        emit IAgentAuditLogV2.ProtocolRevoked(protocol);
        vm.prank(owner);
        auditLog.revokeProtocol(protocol);
        assertFalse(auditLog.isAuthorizedProtocol(protocol));
    }

    function test_revert_authorizeProtocolTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.AlreadyAuthorized.selector, protocol));
        auditLog.authorizeProtocol(protocol);
    }

    function test_revert_authorizeProtocolZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentAuditLogV2.ZeroAddress.selector);
        auditLog.authorizeProtocol(address(0));
    }

    function test_revert_revokeUnauthorizedProtocol() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorized.selector, stranger));
        auditLog.revokeProtocol(stranger);
    }

    function test_revert_authorizeProtocolNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        auditLog.authorizeProtocol(stranger);
    }

    function test_revert_revokeProtocolNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        auditLog.revokeProtocol(protocol);
    }

    // ─── Pause ──────────────────────────────────────────────────────────

    function test_pauseBlocksLog() public {
        vm.prank(owner);
        auditLog.pause();

        vm.prank(agent1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        auditLog.log(agent1, TRANSFER, DATA_HASH, 0);
    }

    function test_pauseBlocksLogBatch() public {
        vm.prank(owner);
        auditLog.pause();

        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(2);
        vm.prank(agent1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        auditLog.logBatch(agent1, t, h, v);
    }

    function test_pauseKeepsReadsWorking() public {
        _logN(agent1, 3);
        vm.prank(owner);
        auditLog.pause();

        assertEq(auditLog.totalLogs(), 3);
        assertEq(auditLog.getLogCount(agent1), 3);
        assertEq(auditLog.getAgentLogs(agent1, 0, 3).length, 3);
        assertEq(auditLog.getLog(0).agent, agent1);
        assertTrue(auditLog.isAuthorizedProtocol(protocol));
    }

    function test_unpauseRestoresLogging() public {
        vm.startPrank(owner);
        auditLog.pause();
        auditLog.unpause();
        vm.stopPrank();

        vm.prank(agent1);
        auditLog.log(agent1, TRANSFER, DATA_HASH, 0);
        assertEq(auditLog.totalLogs(), 1);
    }

    function test_revert_pauseNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        auditLog.pause();
    }

    function test_revert_unpauseNotOwner() public {
        vm.prank(owner);
        auditLog.pause();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        auditLog.unpause();
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_logBatchSize(uint256 size) public {
        size = bound(size, 1, 50);
        (bytes32[] memory t, bytes32[] memory h, uint256[] memory v) = _batch(size);

        vm.prank(agent1);
        uint256 first = auditLog.logBatch(agent1, t, h, v);

        assertEq(first, 0);
        assertEq(auditLog.totalLogs(), size);
        assertEq(auditLog.getLogCount(agent1), size);
        assertEq(auditLog.getLog(size - 1).value, v[size - 1]);
    }

    function testFuzz_pagination(uint256 offset, uint256 limit) public {
        uint256 total = 20;
        _logN(agent1, total);
        offset = bound(offset, 0, 30);
        limit = bound(limit, 0, 30);

        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(agent1, offset, limit);

        uint256 expected;
        if (offset < total) {
            uint256 remaining = total - offset;
            expected = limit < remaining ? limit : remaining;
        }
        assertEq(page.length, expected);
        for (uint256 i; i < page.length; ++i) {
            assertEq(page[i].value, offset + i);
            assertEq(page[i].agent, agent1);
        }
    }

    function testFuzz_logAnyValidInput(address agent, bytes32 actionType, bytes32 dataHash, uint256 value) public {
        vm.assume(agent != address(0));
        vm.assume(actionType != bytes32(0));
        vm.assume(dataHash != bytes32(0));

        vm.prank(protocol);
        uint256 id = auditLog.log(agent, actionType, dataHash, value);

        IAgentAuditLogV2.ActionLog memory l = auditLog.getLog(id);
        assertEq(l.agent, agent);
        assertEq(l.actionType, actionType);
        assertEq(l.dataHash, dataHash);
        assertEq(l.value, value);
    }

    // ─── H-02: two-step ownership ───────────────────────────────────────

    /// @notice H-02: `transferOwnership` only proposes. A mistyped owner cannot brick the contract
    ///         because the current owner keeps every power until the new one accepts.
    function test_H02_transferOwnershipOnlyProposes() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        auditLog.transferOwnership(newOwner);

        assertEq(auditLog.owner(), owner);
        assertEq(auditLog.pendingOwner(), newOwner);
    }

    /// @notice H-02: ownership moves only once the proposed owner accepts.
    function test_H02_acceptOwnershipCompletesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        auditLog.transferOwnership(newOwner);

        vm.prank(newOwner);
        auditLog.acceptOwnership();

        assertEq(auditLog.owner(), newOwner);
        assertEq(auditLog.pendingOwner(), address(0));
    }

    /// @notice H-02: nobody but the proposed owner can accept.
    function test_H02_revert_acceptOwnershipByStranger() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        auditLog.transferOwnership(newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        auditLog.acceptOwnership();

        assertEq(auditLog.owner(), owner);
    }

    /// @notice H-02: a typo'd proposal is recoverable — the real owner just re-proposes.
    function test_H02_pendingOwnerCanBeReplacedBeforeAcceptance() public {
        address typo = makeAddr("typo");
        address newOwner = makeAddr("newOwner");

        vm.startPrank(owner);
        auditLog.transferOwnership(typo);
        auditLog.transferOwnership(newOwner);
        vm.stopPrank();

        assertEq(auditLog.pendingOwner(), newOwner);

        vm.prank(typo);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, typo));
        auditLog.acceptOwnership();
    }
}
