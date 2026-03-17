// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentInsights} from "./interfaces/IAgentInsights.sol";

/// @notice On-chain analytics aggregator for the NexusWeb3 ecosystem. Tracks TVL, volume, fees, agents.
contract AgentInsights is Ownable, ReentrancyGuard, Pausable, IAgentInsights {
    uint256 public constant MAX_HISTORY = 100;

    // well-known metric IDs
    bytes32 public constant VAULT_TVL = keccak256("VAULT_TVL");
    bytes32 public constant REGISTRY_AGENTS = keccak256("REGISTRY_AGENTS");
    bytes32 public constant ESCROW_VOLUME = keccak256("ESCROW_VOLUME");
    bytes32 public constant YIELD_TVL = keccak256("YIELD_TVL");
    bytes32 public constant INSURANCE_POOL = keccak256("INSURANCE_POOL");
    bytes32 public constant REPUTATION_QUERIES = keccak256("REPUTATION_QUERIES");
    bytes32 public constant MARKET_VOLUME = keccak256("MARKET_VOLUME");
    bytes32 public constant BRIDGE_OPS = keccak256("BRIDGE_OPS");
    bytes32 public constant STAKING_TVL = keccak256("STAKING_TVL");
    bytes32 public constant TOTAL_FEES_ETH = keccak256("TOTAL_FEES_ETH");
    bytes32 public constant TOTAL_FEES_USDC = keccak256("TOTAL_FEES_USDC");

    uint256 public queryFee;
    address public treasury;
    uint256 public accumulatedFees;

    EcosystemStats private _snapshot;

    mapping(address => bool) private _authorizedProtocols;
    mapping(bytes32 => MetricEntry[]) private _history;
    mapping(bytes32 => bool) private _metricExists;

    constructor(address treasury_, address owner_, uint256 queryFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        queryFee = queryFee_;
    }

    // ─── Record (authorized protocols only) ─────────────────────────────

    /// @notice Record a metric value. Only authorized protocols can call.
    function recordMetric(bytes32 metricId, uint256 value) external whenNotPaused {
        if (!_authorizedProtocols[msg.sender]) revert NotAuthorizedProtocol(msg.sender);

        uint48 ts = uint48(block.timestamp);
        MetricEntry[] storage hist = _history[metricId];

        // cap history length
        if (hist.length >= MAX_HISTORY) {
            // shift left: drop oldest
            for (uint256 i; i < hist.length - 1; i++) {
                hist[i] = hist[i + 1];
            }
            hist.pop();
        }

        hist.push(MetricEntry({value: value, timestamp: ts}));
        _metricExists[metricId] = true;

        emit MetricRecorded(metricId, value, ts, msg.sender);
    }

    // ─── Snapshot ────────────────────────────────────────────────────────

    /// @notice Update the ecosystem snapshot. Only authorized protocols or owner.
    function updateSnapshot(EcosystemStats calldata stats) external {
        if (!_authorizedProtocols[msg.sender] && msg.sender != owner()) {
            revert NotAuthorizedProtocol(msg.sender);
        }
        _snapshot = stats;
        _snapshot.snapshotTimestamp = uint48(block.timestamp);
        emit SnapshotUpdated(uint48(block.timestamp));
    }

    // ─── Query (free) ───────────────────────────────────────────────────

    /// @notice Get latest value for a metric. Free view.
    function getMetric(bytes32 metricId) external view returns (uint256 value, uint48 timestamp) {
        if (!_metricExists[metricId]) revert MetricNotFound(metricId);
        MetricEntry[] storage hist = _history[metricId];
        MetricEntry storage latest = hist[hist.length - 1];
        return (latest.value, latest.timestamp);
    }

    /// @notice Get history for a metric. Free view.
    function getMetricHistory(bytes32 metricId, uint256 limit) external view returns (uint256[] memory values, uint48[] memory timestamps) {
        if (!_metricExists[metricId]) revert MetricNotFound(metricId);
        MetricEntry[] storage hist = _history[metricId];

        uint256 count = limit > hist.length ? hist.length : limit;
        uint256 start = hist.length - count;

        values = new uint256[](count);
        timestamps = new uint48[](count);
        for (uint256 i; i < count; i++) {
            values[i] = hist[start + i].value;
            timestamps[i] = hist[start + i].timestamp;
        }
    }

    /// @notice Get the ecosystem snapshot. Free view.
    function getEcosystemSnapshot() external view returns (EcosystemStats memory) {
        return _snapshot;
    }

    // ─── Query (paid) ───────────────────────────────────────────────────

    /// @notice Batch query multiple metrics. Costs queryFee.
    function queryMetrics(bytes32[] calldata metricIds) external payable returns (uint256[] memory values) {
        if (metricIds.length == 0) revert EmptyQuery();
        if (msg.value < queryFee) revert InsufficientFee(queryFee, msg.value);

        accumulatedFees += msg.value;
        values = new uint256[](metricIds.length);

        for (uint256 i; i < metricIds.length; i++) {
            MetricEntry[] storage hist = _history[metricIds[i]];
            if (hist.length > 0) {
                values[i] = hist[hist.length - 1].value;
            }
        }
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

    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);
        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocols[protocol]) revert NotAuthorized(protocol);
        _authorizedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    function setQueryFee(uint256 newFee) external onlyOwner {
        uint256 old = queryFee;
        queryFee = newFee;
        emit QueryFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
