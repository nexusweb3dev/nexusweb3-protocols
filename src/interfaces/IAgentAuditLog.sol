// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentAuditLog {
    struct ActionLog {
        address agent;
        address caller;
        bytes32 actionType;
        bytes32 dataHash;
        uint256 value;
        uint48 timestamp;
        uint256 blockNumber;
    }

    event ActionLogged(uint256 indexed logId, address indexed agent, bytes32 indexed actionType, bytes32 dataHash);
    event BatchLogged(address indexed agent, uint256 count, uint256 firstId);
    event LoggerAuthorized(address indexed agent, address indexed logger);
    event LoggerRevoked(address indexed agent, address indexed logger);
    event LogFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error NotAgentOrLogger(address agent, address caller);
    error InvalidDataHash();
    error InvalidActionType();
    error LogNotFound(uint256 logId);
    error EmptyBatch();
    error BatchTooLarge(uint256 size);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
    error InvalidRange();
}
