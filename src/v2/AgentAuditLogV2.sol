// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentAccess} from "./interfaces/IAgentAccess.sol";
import {IAgentAuditLogV2} from "./interfaces/IAgentAuditLogV2.sol";
import {OperatorGated} from "./OperatorGated.sol";

/// @title AgentAuditLogV2
/// @notice Free, append-only action log for AI agents. An entry may be written by the agent
///         principal, one of its operators (via AgentAccess), or an owner-authorized protocol.
///         No fees and no ETH handling anywhere in this contract; every read is a free `view`.
contract AgentAuditLogV2 is OperatorGated, Ownable, Pausable, IAgentAuditLogV2 {
    /// @notice Maximum number of entries accepted by a single `logBatch` call.
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Thrown when a log id is read that has never been written.
    error LogNotFound(uint256 logId);

    ActionLog[] private _logs;
    mapping(address => uint256[]) private _agentLogIds;
    mapping(address => bool) private _authorizedProtocols;

    /// @param access_ AgentAccess singleton used to resolve agent/operator authority.
    /// @param owner_ Address receiving contract ownership.
    constructor(IAgentAccess access_, address owner_) OperatorGated(access_) Ownable(owner_) {}

    // ─── Log ────────────────────────────────────────────────────────────

    /// @notice Append a single action to `agent`'s log.
    /// @param agent Agent the action belongs to; must not be the zero address.
    /// @param actionType Non-zero identifier of the action performed.
    /// @param dataHash Non-zero hash committing to the action payload.
    /// @param value Free-form numeric value attached to the action.
    /// @return logId Global, zero-based id of the appended entry.
    function log(
        address agent,
        bytes32 actionType,
        bytes32 dataHash,
        uint256 value
    )
        external
        whenNotPaused
        returns (uint256 logId)
    {
        if (agent == address(0)) revert ZeroAddress();
        _requireLogger(agent);
        logId = _append(agent, actionType, dataHash, value);
    }

    /// @notice Append up to `MAX_BATCH_SIZE` actions to `agent`'s log in one call.
    /// @param agent Agent the actions belong to; must not be the zero address.
    /// @param actionTypes Non-zero action identifiers, one per entry.
    /// @param dataHashes Non-zero payload hashes, one per entry.
    /// @param values Numeric values, one per entry.
    /// @return firstLogId Global id of the first appended entry.
    function logBatch(
        address agent,
        bytes32[] calldata actionTypes,
        bytes32[] calldata dataHashes,
        uint256[] calldata values
    )
        external
        whenNotPaused
        returns (uint256 firstLogId)
    {
        if (agent == address(0)) revert ZeroAddress();
        uint256 count = actionTypes.length;
        if (count != dataHashes.length || count != values.length) revert LengthMismatch();
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchTooLarge(count);
        _requireLogger(agent);

        firstLogId = _logs.length;
        for (uint256 i; i < count; ++i) {
            _append(agent, actionTypes[i], dataHashes[i], values[i]);
        }
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @notice Read one entry by its global id. Reverts if the id was never written.
    function getLog(uint256 logId) external view returns (ActionLog memory) {
        if (logId >= _logs.length) revert LogNotFound(logId);
        return _logs[logId];
    }

    /// @notice Number of entries logged for `agent`.
    function getLogCount(address agent) external view returns (uint256) {
        return _agentLogIds[agent].length;
    }

    /// @notice Paginated read of `agent`'s entries in append order.
    /// @param offset Index into the agent's own list; an out-of-range offset returns an empty array.
    /// @param limit Maximum entries to return; clipped to the number remaining after `offset`.
    function getAgentLogs(address agent, uint256 offset, uint256 limit) external view returns (ActionLog[] memory) {
        uint256[] storage ids = _agentLogIds[agent];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new ActionLog[](0);

        uint256 remaining = total - offset;
        uint256 size = limit < remaining ? limit : remaining;
        ActionLog[] memory result = new ActionLog[](size);
        for (uint256 i; i < size; ++i) {
            result[i] = _logs[ids[offset + i]];
        }
        return result;
    }

    /// @notice Total number of entries ever appended across all agents.
    function totalLogs() external view returns (uint256) {
        return _logs.length;
    }

    /// @notice True if `protocol` may log on behalf of any agent.
    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    // ─── Owner ──────────────────────────────────────────────────────────

    /// @notice Allow `protocol` to log on behalf of any agent.
    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);
        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    /// @notice Revoke a protocol's logging authority.
    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocols[protocol]) revert NotAuthorized(protocol);
        _authorizedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    /// @notice Block all writes. Reads stay available while paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume writes.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Caller must be the agent, a valid operator for it, or an authorized protocol.
    function _requireLogger(address agent) private view {
        if (_authorizedProtocols[msg.sender]) return;
        if (!access.isOperatorFor(agent, msg.sender)) revert NotAuthorizedLogger(agent, msg.sender);
    }

    /// @dev Validate and append one entry; emits `ActionLogged`.
    function _append(
        address agent,
        bytes32 actionType,
        bytes32 dataHash,
        uint256 value
    )
        private
        returns (uint256 logId)
    {
        if (actionType == bytes32(0)) revert InvalidActionType();
        if (dataHash == bytes32(0)) revert InvalidDataHash();

        logId = _logs.length;
        _logs.push(
            ActionLog({
                agent: agent,
                caller: msg.sender,
                actionType: actionType,
                dataHash: dataHash,
                value: value,
                timestamp: uint48(block.timestamp),
                blockNumber: uint64(block.number)
            })
        );
        _agentLogIds[agent].push(logId);

        emit ActionLogged(logId, agent, actionType, msg.sender, dataHash, value);
    }
}
