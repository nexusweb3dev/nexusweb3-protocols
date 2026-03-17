// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentAuditLog} from "./interfaces/IAgentAuditLog.sol";

/// @notice Immutable on-chain audit log for AI agent actions. Append-only, tamper-proof.
contract AgentAuditLog is Ownable, ReentrancyGuard, Pausable, IAgentAuditLog {
    uint256 public constant MAX_BATCH_SIZE = 50;

    uint256 public logFee;
    address public treasury;
    uint256 public totalLogs;
    uint256 public accumulatedFees;

    mapping(uint256 => ActionLog) private _logs;
    mapping(address => uint256[]) private _agentLogIds;
    mapping(address => mapping(address => bool)) private _authorizedLoggers;

    constructor(address treasury_, address owner_, uint256 logFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        logFee = logFee_;
    }

    // ─── Log Action ─────────────────────────────────────────────────────

    /// @notice Log a single agent action permanently on-chain.
    function logAction(
        address agent,
        bytes32 actionType,
        bytes32 dataHash,
        uint256 value
    ) external payable nonReentrant whenNotPaused returns (uint256 logId) {
        if (agent == address(0)) revert ZeroAddress();
        if (dataHash == bytes32(0)) revert InvalidDataHash();
        if (actionType == bytes32(0)) revert InvalidActionType();
        if (msg.sender != agent && !_authorizedLoggers[agent][msg.sender]) {
            revert NotAgentOrLogger(agent, msg.sender);
        }
        if (msg.value < logFee) revert InsufficientFee(logFee, msg.value);

        logId = totalLogs++;
        _logs[logId] = ActionLog({
            agent: agent,
            caller: msg.sender,
            actionType: actionType,
            dataHash: dataHash,
            value: value,
            timestamp: uint48(block.timestamp),
            blockNumber: block.number
        });
        _agentLogIds[agent].push(logId);
        accumulatedFees += msg.value;

        emit ActionLogged(logId, agent, actionType, dataHash);
    }

    /// @notice Batch log multiple actions in one transaction.
    function logActionBatch(
        address agent,
        bytes32[] calldata actionTypes,
        bytes32[] calldata dataHashes,
        uint256[] calldata values
    ) external payable nonReentrant whenNotPaused returns (uint256 firstId) {
        uint256 count = actionTypes.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge(count);
        if (count != dataHashes.length || count != values.length) revert EmptyBatch();
        if (agent == address(0)) revert ZeroAddress();
        if (msg.sender != agent && !_authorizedLoggers[agent][msg.sender]) {
            revert NotAgentOrLogger(agent, msg.sender);
        }

        uint256 totalFee = logFee * count;
        if (msg.value < totalFee) revert InsufficientFee(totalFee, msg.value);

        firstId = totalLogs;

        for (uint256 i; i < count; i++) {
            if (dataHashes[i] == bytes32(0)) revert InvalidDataHash();
            if (actionTypes[i] == bytes32(0)) revert InvalidActionType();

            uint256 logId = totalLogs++;
            _logs[logId] = ActionLog({
                agent: agent,
                caller: msg.sender,
                actionType: actionTypes[i],
                dataHash: dataHashes[i],
                value: values[i],
                timestamp: uint48(block.timestamp),
                blockNumber: block.number
            });
            _agentLogIds[agent].push(logId);
        }

        accumulatedFees += msg.value;
        emit BatchLogged(agent, count, firstId);
    }

    // ─── Verify ─────────────────────────────────────────────────────────

    /// @notice Verify a logged action matches an expected data hash.
    function verifyAction(uint256 logId, bytes32 expectedHash) external view returns (bool) {
        if (logId >= totalLogs) revert LogNotFound(logId);
        return _logs[logId].dataHash == expectedHash;
    }

    // ─── Logger Authorization ───────────────────────────────────────────

    /// @notice Authorize an external address to log actions for an agent.
    function authorizeLogger(address logger) external {
        if (logger == address(0)) revert ZeroAddress();
        _authorizedLoggers[msg.sender][logger] = true;
        emit LoggerAuthorized(msg.sender, logger);
    }

    /// @notice Revoke a logger's authorization.
    function revokeLogger(address logger) external {
        _authorizedLoggers[msg.sender][logger] = false;
        emit LoggerRevoked(msg.sender, logger);
    }

    function isAuthorizedLogger(address agent, address logger) external view returns (bool) {
        return _authorizedLoggers[agent][logger];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Fee transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setLogFee(uint256 newFee) external onlyOwner {
        uint256 old = logFee;
        logFee = newFee;
        emit LogFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getLog(uint256 logId) external view returns (ActionLog memory) {
        if (logId >= totalLogs) revert LogNotFound(logId);
        return _logs[logId];
    }

    function getLogCount(address agent) external view returns (uint256) {
        return _agentLogIds[agent].length;
    }

    function getAgentLogs(address agent, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] storage ids = _agentLogIds[agent];
        if (offset >= ids.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = ids[i];
        }
        return result;
    }
}
