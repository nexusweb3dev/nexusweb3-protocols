// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentAuditLog} from "../src/AgentAuditLog.sol";
import {IAgentAuditLog} from "../src/interfaces/IAgentAuditLog.sol";

contract AgentAuditLogTest is Test {
    AgentAuditLog auditLog;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address logger = makeAddr("logger");
    address stranger = makeAddr("stranger");

    uint256 constant LOG_FEE = 0.0001 ether;
    bytes32 constant TRANSFER = keccak256("TRANSFER");
    bytes32 constant VOTE = keccak256("VOTE");
    bytes32 constant DATA_HASH = keccak256("some-data");

    function setUp() public {
        auditLog = new AgentAuditLog(treasury, owner, LOG_FEE);
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(logger, 10 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(auditLog.treasury(), treasury);
        assertEq(auditLog.logFee(), LOG_FEE);
        assertEq(auditLog.totalLogs(), 0);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentAuditLog.ZeroAddress.selector);
        new AgentAuditLog(address(0), owner, LOG_FEE);
    }

    // ─── Log Action ─────────────────────────────────────────────────────

    function test_logAction() public {
        vm.prank(agent1);
        uint256 id = auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 100);

        assertEq(id, 0);
        assertEq(auditLog.totalLogs(), 1);
        assertEq(auditLog.getLogCount(agent1), 1);

        IAgentAuditLog.ActionLog memory l = auditLog.getLog(id);
        assertEq(l.agent, agent1);
        assertEq(l.caller, agent1);
        assertEq(l.actionType, TRANSFER);
        assertEq(l.dataHash, DATA_HASH);
        assertEq(l.value, 100);
        assertEq(l.blockNumber, block.number);
    }

    function test_logByAuthorizedLogger() public {
        vm.prank(agent1);
        auditLog.authorizeLogger(logger);

        vm.prank(logger);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 50);

        IAgentAuditLog.ActionLog memory l = auditLog.getLog(0);
        assertEq(l.agent, agent1);
        assertEq(l.caller, logger);
    }

    function test_logCollectsFee() public {
        vm.prank(agent1);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);
        assertEq(auditLog.accumulatedFees(), LOG_FEE);
    }

    function test_revert_logByStranger() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.NotAgentOrLogger.selector, agent1, stranger));
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logZeroDataHash() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLog.InvalidDataHash.selector);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, bytes32(0), 0);
    }

    function test_revert_logZeroActionType() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLog.InvalidActionType.selector);
        auditLog.logAction{value: LOG_FEE}(agent1, bytes32(0), DATA_HASH, 0);
    }

    function test_revert_logInsufficientFee() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.InsufficientFee.selector, LOG_FEE, 0));
        auditLog.logAction(agent1, TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logZeroAgent() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLog.ZeroAddress.selector);
        auditLog.logAction{value: LOG_FEE}(address(0), TRANSFER, DATA_HASH, 0);
    }

    function test_revert_logWhenPaused() public {
        vm.prank(owner);
        auditLog.pause();

        vm.prank(agent1);
        vm.expectRevert();
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);
    }

    // ─── Batch Log ──────────────────────────────────────────────────────

    function test_logActionBatch() public {
        bytes32[] memory types = new bytes32[](3);
        bytes32[] memory hashes = new bytes32[](3);
        uint256[] memory values = new uint256[](3);
        types[0] = TRANSFER; types[1] = VOTE; types[2] = TRANSFER;
        hashes[0] = keccak256("a"); hashes[1] = keccak256("b"); hashes[2] = keccak256("c");
        values[0] = 10; values[1] = 20; values[2] = 30;

        vm.prank(agent1);
        uint256 firstId = auditLog.logActionBatch{value: LOG_FEE * 3}(agent1, types, hashes, values);

        assertEq(firstId, 0);
        assertEq(auditLog.totalLogs(), 3);
        assertEq(auditLog.getLogCount(agent1), 3);
        assertEq(auditLog.getLog(1).actionType, VOTE);
    }

    function test_revert_batchEmpty() public {
        bytes32[] memory t = new bytes32[](0);
        bytes32[] memory h = new bytes32[](0);
        uint256[] memory v = new uint256[](0);

        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLog.EmptyBatch.selector);
        auditLog.logActionBatch{value: 0}(agent1, t, h, v);
    }

    function test_revert_batchTooLarge() public {
        bytes32[] memory t = new bytes32[](51);
        bytes32[] memory h = new bytes32[](51);
        uint256[] memory v = new uint256[](51);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.BatchTooLarge.selector, 51));
        auditLog.logActionBatch{value: LOG_FEE * 51}(agent1, t, h, v);
    }

    function test_revert_batchInsufficientFee() public {
        bytes32[] memory t = new bytes32[](2);
        bytes32[] memory h = new bytes32[](2);
        uint256[] memory v = new uint256[](2);
        t[0] = TRANSFER; t[1] = VOTE;
        h[0] = DATA_HASH; h[1] = DATA_HASH;

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.InsufficientFee.selector, LOG_FEE * 2, LOG_FEE));
        auditLog.logActionBatch{value: LOG_FEE}(agent1, t, h, v);
    }

    // ─── Verify ─────────────────────────────────────────────────────────

    function test_verifyAction() public {
        vm.prank(agent1);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);

        assertTrue(auditLog.verifyAction(0, DATA_HASH));
        assertFalse(auditLog.verifyAction(0, keccak256("wrong")));
    }

    function test_revert_verifyNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.LogNotFound.selector, 999));
        auditLog.verifyAction(999, DATA_HASH);
    }

    // ─── Logger Authorization ───────────────────────────────────────────

    function test_authorizeLogger() public {
        vm.prank(agent1);
        auditLog.authorizeLogger(logger);

        assertTrue(auditLog.isAuthorizedLogger(agent1, logger));
    }

    function test_revokeLogger() public {
        vm.prank(agent1);
        auditLog.authorizeLogger(logger);
        vm.prank(agent1);
        auditLog.revokeLogger(logger);

        assertFalse(auditLog.isAuthorizedLogger(agent1, logger));
    }

    function test_revert_authorizeZero() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAuditLog.ZeroAddress.selector);
        auditLog.authorizeLogger(address(0));
    }

    // ─── Pagination ─────────────────────────────────────────────────────

    function test_getAgentLogsPaginated() public {
        vm.startPrank(agent1);
        for (uint i; i < 10; i++) {
            auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, keccak256(abi.encode(i)), i);
        }
        vm.stopPrank();

        uint256[] memory page1 = auditLog.getAgentLogs(agent1, 0, 5);
        assertEq(page1.length, 5);
        assertEq(page1[0], 0);

        uint256[] memory page2 = auditLog.getAgentLogs(agent1, 5, 5);
        assertEq(page2.length, 5);
        assertEq(page2[0], 5);
    }

    function test_getAgentLogsOffsetBeyondLength() public view {
        uint256[] memory empty = auditLog.getAgentLogs(agent1, 100, 10);
        assertEq(empty.length, 0);
    }

    // ─── Immutability ───────────────────────────────────────────────────

    function test_noDeleteFunction() public {
        vm.prank(agent1);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);

        // there is no delete/modify function — logs are permanent
        // verify the log still exists after time passes
        vm.warp(block.timestamp + 365 days);
        IAgentAuditLog.ActionLog memory l = auditLog.getLog(0);
        assertEq(l.dataHash, DATA_HASH);
    }

    function test_sequentialIds() public {
        vm.startPrank(agent1);
        uint256 id0 = auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);
        uint256 id1 = auditLog.logAction{value: LOG_FEE}(agent1, VOTE, DATA_HASH, 0);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        vm.prank(agent1);
        auditLog.logAction{value: LOG_FEE}(agent1, TRANSFER, DATA_HASH, 0);

        uint256 before_ = treasury.balance;
        auditLog.collectFees();
        assertEq(treasury.balance - before_, LOG_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentAuditLog.NoFeesToCollect.selector);
        auditLog.collectFees();
    }

    function test_setLogFee() public {
        vm.prank(owner);
        auditLog.setLogFee(0.0005 ether);
        assertEq(auditLog.logFee(), 0.0005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        auditLog.setTreasury(newT);
        assertEq(auditLog.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentAuditLog.ZeroAddress.selector);
        auditLog.setTreasury(address(0));
    }

    function test_revert_getLogNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLog.LogNotFound.selector, 0));
        auditLog.getLog(0);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_logAndVerify(bytes32 actionType, bytes32 dataHash, uint256 value) public {
        vm.assume(actionType != bytes32(0) && dataHash != bytes32(0));

        vm.prank(agent1);
        uint256 id = auditLog.logAction{value: LOG_FEE}(agent1, actionType, dataHash, value);

        assertTrue(auditLog.verifyAction(id, dataHash));
        assertEq(auditLog.getLog(id).value, value);
    }

    function testFuzz_batchSize(uint8 count) public {
        count = uint8(bound(count, 1, 50));

        bytes32[] memory t = new bytes32[](count);
        bytes32[] memory h = new bytes32[](count);
        uint256[] memory v = new uint256[](count);
        for (uint i; i < count; i++) {
            t[i] = TRANSFER;
            h[i] = keccak256(abi.encode(i));
            v[i] = i;
        }

        vm.prank(agent1);
        auditLog.logActionBatch{value: LOG_FEE * count}(agent1, t, h, v);

        assertEq(auditLog.totalLogs(), count);
        assertEq(auditLog.getLogCount(agent1), count);
    }
}
