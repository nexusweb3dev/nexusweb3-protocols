// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentInsights {
    struct MetricEntry {
        uint256 value;
        uint48 timestamp;
    }

    struct EcosystemStats {
        uint256 totalTVL;
        uint256 totalAgents;
        uint256 totalVolume24h;
        uint256 totalFeesCollected;
        uint256 activeEscrows;
        uint256 activeInsuranceMembers;
        uint256 nexusStaked;
        uint48 snapshotTimestamp;
    }

    event MetricRecorded(bytes32 indexed metricId, uint256 value, uint48 timestamp, address indexed recorder);
    event SnapshotUpdated(uint48 timestamp);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);
    event QueryFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error MetricNotFound(bytes32 metricId);
    error InsufficientFee(uint256 required, uint256 provided);
    error EmptyQuery();
    error ZeroAddress();
    error NoFeesToCollect();
}
