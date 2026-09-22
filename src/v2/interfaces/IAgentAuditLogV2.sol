// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentAuditLogV2
/// @notice Free, append-only per-agent action log. Writable by the agent, its operators, or
///         authorized protocols (which log on behalf of any agent). Paginated reads.
interface IAgentAuditLogV2 {
    struct ActionLog {
        address agent;
        address caller;
        bytes32 actionType;
        bytes32 dataHash;
        uint256 value;
        uint48 timestamp;
        uint64 blockNumber;
    }

    event ActionLogged(
        uint256 indexed logId,
        address indexed agent,
        bytes32 indexed actionType,
        address caller,
        bytes32 dataHash,
        uint256 value
    );
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    error NotAuthorizedLogger(address agent, address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error InvalidActionType();
    error InvalidDataHash();
    error ZeroAddress();
    error BatchTooLarge(uint256 size);
    error LengthMismatch();

    function log(address agent, bytes32 actionType, bytes32 dataHash, uint256 value) external returns (uint256 logId);
    function logBatch(
        address agent,
        bytes32[] calldata actionTypes,
        bytes32[] calldata dataHashes,
        uint256[] calldata values
    )
        external
        returns (uint256 firstLogId);

    function getLog(uint256 logId) external view returns (ActionLog memory);
    function getLogCount(address agent) external view returns (uint256);
    /// @notice Page of `agent`'s entries; `limit` is clipped to at most 200 entries.
    function getAgentLogs(address agent, uint256 offset, uint256 limit) external view returns (ActionLog[] memory);
    function totalLogs() external view returns (uint256);
    function isAuthorizedProtocol(address protocol) external view returns (bool);

    function authorizeProtocol(address protocol) external;
    function revokeProtocol(address protocol) external;
}
