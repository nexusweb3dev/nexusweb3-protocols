// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentKillSwitchV2
/// @notice Opt-in spending guard enforced by authorized protocols via `consume`. Config changes and
///         session resets are principal-only (never operators, never guardians); kill/pause/unpause
///         can also be done by a guardian, which may only restrict spending. Sessions auto-roll when
///         expired. Unregistered agents are treated as active with no limits.
interface IAgentKillSwitchV2 {
    struct AgentConfig {
        uint128 spendingLimit; // per session, 6-decimal USDC units
        uint128 spent; // this session
        uint32 txLimit; // per session (0 = unlimited)
        uint32 txCount; // this session
        uint48 sessionDuration; // seconds
        uint48 sessionStart;
        bool registered;
        bool killed;
        bool paused;
    }

    event AgentRegistered(address indexed agent, uint128 spendingLimit, uint32 txLimit, uint48 sessionDuration);
    event LimitsUpdated(address indexed agent, uint128 spendingLimit, uint32 txLimit, uint48 sessionDuration);
    event GuardianSet(address indexed agent, address indexed guardian);
    event AgentKilled(address indexed agent, address indexed by);
    event AgentResumed(address indexed agent);
    event AgentPaused(address indexed agent, address indexed by);
    event AgentUnpaused(address indexed agent, address indexed by);
    event SessionReset(address indexed agent, uint48 sessionStart);
    event SpendConsumed(address indexed agent, address indexed protocol, uint256 amount);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error NotPrincipal(address agent, address caller);
    error NotPrincipalOrGuardian(address agent, address caller);
    error AlreadyRegistered(address agent);
    error NotRegistered(address agent);
    error AgentIsKilled(address agent);
    error AgentIsPaused(address agent);
    error NotKilled(address agent);
    error NotPaused(address agent);
    error SpendingLimitExceeded(address agent, uint256 requested, uint256 remaining);
    error TxLimitExceeded(address agent, uint32 txLimit);
    error InvalidSessionDuration(uint48 sessionDuration);
    error ZeroAddress();

    // ─── Principal only (msg.sender == agent) ───────────────────────────
    function register(uint128 spendingLimit, uint32 txLimit, uint48 sessionDuration) external;
    function setLimits(uint128 spendingLimit, uint32 txLimit, uint48 sessionDuration) external;
    function setGuardian(address guardian) external;
    function resume() external; // un-kill, principal only
    /// @notice Zero the session counters and start a fresh session. Principal-only: a reset restores
    ///         spending headroom, so the restrict-only guardian role must not be able to call it.
    function resetSession(address agent) external;

    // ─── Principal or guardian (restrict only) ──────────────────────────
    function kill(address agent) external;
    function pause(address agent) external;
    function unpause(address agent) external;

    // ─── Authorized protocols ───────────────────────────────────────────
    /// @notice Enforce limits for `agent` spending `amount`. Reverts if killed, paused, or over limit.
    ///         No-op for unregistered agents. Rolls the session if expired.
    function consume(address agent, uint256 amount) external;

    // ─── Views ──────────────────────────────────────────────────────────
    function isActive(address agent) external view returns (bool); // !killed && !paused
    function getConfig(address agent) external view returns (AgentConfig memory);
    /// @notice Spend left this session; max if unregistered, 0 if the limit was lowered below spent.
    function remainingSpend(address agent) external view returns (uint256);
    function guardianOf(address agent) external view returns (address);
    function isAuthorizedProtocol(address protocol) external view returns (bool);

    function authorizeProtocol(address protocol) external;
    function revokeProtocol(address protocol) external;
}
