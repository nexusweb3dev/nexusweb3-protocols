// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentReputationV2
/// @notice Value-weighted reputation written by authorized protocols (Escrow etc.). All reads free.
///         score = BASE + POSITIVE_POINTS*positives + volumeUsdc/VOLUME_UNIT - NEGATIVE_POINTS*negatives,
///         floored at 0. Tiers: BRONZE <200, SILVER >=200, GOLD >=500, PLATINUM >=1000.
interface IAgentReputationV2 {
    enum Tier {
        BRONZE,
        SILVER,
        GOLD,
        PLATINUM
    }

    struct Stats {
        uint64 positives;
        uint64 negatives;
        uint128 volumeUsdc; // cumulative settled value (6 decimals)
        uint48 firstSeen;
        uint48 lastActivity;
    }

    event InteractionRecorded(
        address indexed agent, address indexed recorder, bool positive, uint8 category, uint256 valueUsdc
    );
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error InvalidCategory(uint8 category);
    error ZeroAddress();

    /// @notice Record an interaction. Only authorized protocols. category 0..4
    ///         (0 PAYMENT, 1 ESCROW, 2 YIELD, 3 INSURANCE, 4 GENERAL).
    function recordInteraction(address agent, bool positive, uint8 category, uint256 valueUsdc) external;

    function getScore(address agent) external view returns (uint256);
    function getTier(address agent) external view returns (Tier);
    function getStats(address agent) external view returns (Stats memory);
    function isAuthorizedProtocol(address protocol) external view returns (bool);

    function authorizeProtocol(address protocol) external;
    function revokeProtocol(address protocol) external;
}
