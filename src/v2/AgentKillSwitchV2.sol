// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAgentKillSwitchV2} from "./interfaces/IAgentKillSwitchV2.sol";

/// @title AgentKillSwitchV2
/// @notice Opt-in spending guard for AI agents, enforced by authorized protocols via `consume`.
/// @dev Deliberately NOT Pausable: a global owner pause must never be able to freeze the spending
///      of every registered agent. The contract holds no ETH and charges no fees. Config changes and
///      session resets are principal-only (`msg.sender` is the agent) so neither an operator hot key
///      nor a guardian can widen limits or refresh spending headroom. A guardian may only restrict:
///      kill, pause and unpause.
contract AgentKillSwitchV2 is Ownable2Step, IAgentKillSwitchV2 {
    /// @notice Inclusive bounds on the session length a principal may configure.
    uint48 public constant MIN_SESSION_DURATION = 1 hours;
    uint48 public constant MAX_SESSION_DURATION = 365 days;

    mapping(address => AgentConfig) private _configs;
    mapping(address => address) private _guardians;
    mapping(address => bool) private _authorizedProtocols;

    /// @param owner_ Owner allowed to authorize and revoke protocol callers.
    /// @dev A zero owner is rejected by `Ownable` with `OwnableInvalidOwner`.
    constructor(address owner_) Ownable(owner_) {}

    modifier onlyRegistered(address agent) {
        _requireRegistered(agent);
        _;
    }

    modifier onlyPrincipalOrGuardian(address agent) {
        _requirePrincipalOrGuardian(agent);
        _;
    }

    modifier onlyPrincipal(address agent) {
        if (msg.sender != agent) revert NotPrincipal(agent, msg.sender);
        _;
    }

    // ─── Principal only (msg.sender == agent) ───────────────────────────

    /// @notice Register the caller as an agent and start its first session.
    /// @param spendingLimit Maximum spend per session, in 6-decimal USDC units.
    /// @param txLimit Maximum consumes per session; 0 means unlimited.
    /// @param sessionDuration Session length in seconds, between 1 hour and 365 days.
    function register(uint128 spendingLimit, uint32 txLimit, uint48 sessionDuration) external {
        AgentConfig storage c = _configs[msg.sender];
        if (c.registered) revert AlreadyRegistered(msg.sender);
        _validateDuration(sessionDuration);

        // spent and txCount are already zero: `registered` is never cleared, so this slot is fresh.
        c.spendingLimit = spendingLimit;
        c.txLimit = txLimit;
        c.sessionDuration = sessionDuration;
        c.sessionStart = _now();
        c.registered = true;

        emit AgentRegistered(msg.sender, spendingLimit, txLimit, sessionDuration);
    }

    /// @notice Update the caller's limits. Current session counters are left untouched.
    /// @param spendingLimit New maximum spend per session, in 6-decimal USDC units.
    /// @param txLimit New maximum consumes per session; 0 means unlimited.
    /// @param sessionDuration New session length in seconds, between 1 hour and 365 days.
    function setLimits(
        uint128 spendingLimit,
        uint32 txLimit,
        uint48 sessionDuration
    )
        external
        onlyRegistered(msg.sender)
    {
        _validateDuration(sessionDuration);
        AgentConfig storage c = _configs[msg.sender];
        c.spendingLimit = spendingLimit;
        c.txLimit = txLimit;
        c.sessionDuration = sessionDuration;

        emit LimitsUpdated(msg.sender, spendingLimit, txLimit, sessionDuration);
    }

    /// @notice Set or clear the caller's guardian, which may kill, pause and unpause the agent.
    /// @dev A guardian can only restrict spending; it can never reset a session or change limits.
    /// @param guardian Guardian address; the zero address clears the current guardian.
    function setGuardian(address guardian) external onlyRegistered(msg.sender) {
        _guardians[msg.sender] = guardian;
        emit GuardianSet(msg.sender, guardian);
    }

    /// @notice Zero the session counters for `agent` and start a fresh session now.
    /// @dev Principal-only: a session reset restores spending headroom, so a guardian (a restrict-only
    ///      role) must not be able to call it.
    /// @param agent Agent whose session is reset; must be the caller.
    function resetSession(address agent) external onlyRegistered(agent) onlyPrincipal(agent) {
        _rollSession(_configs[agent], agent);
    }

    /// @notice Clear the caller's killed flag. Only the principal can un-kill an agent.
    function resume() external onlyRegistered(msg.sender) {
        AgentConfig storage c = _configs[msg.sender];
        if (!c.killed) revert NotKilled(msg.sender);
        c.killed = false;
        emit AgentResumed(msg.sender);
    }

    // ─── Principal or guardian ──────────────────────────────────────────

    /// @notice Stop all spending for `agent` until the principal resumes it.
    /// @param agent Agent to kill.
    function kill(address agent) external onlyRegistered(agent) onlyPrincipalOrGuardian(agent) {
        AgentConfig storage c = _configs[agent];
        if (c.killed) revert AgentIsKilled(agent);
        c.killed = true;
        emit AgentKilled(agent, msg.sender);
    }

    /// @notice Temporarily stop all spending for `agent`.
    /// @param agent Agent to pause.
    function pause(address agent) external onlyRegistered(agent) onlyPrincipalOrGuardian(agent) {
        AgentConfig storage c = _configs[agent];
        if (c.paused) revert AgentIsPaused(agent);
        c.paused = true;
        emit AgentPaused(agent, msg.sender);
    }

    /// @notice Lift a pause on `agent`.
    /// @param agent Agent to unpause.
    function unpause(address agent) external onlyRegistered(agent) onlyPrincipalOrGuardian(agent) {
        AgentConfig storage c = _configs[agent];
        if (!c.paused) revert NotPaused(agent);
        c.paused = false;
        emit AgentUnpaused(agent, msg.sender);
    }

    // ─── Authorized protocols ───────────────────────────────────────────

    /// @notice Enforce limits for `agent` spending `amount` and record the usage.
    /// @dev No-op for unregistered agents. Rolls the session first if it has expired.
    /// @param agent Agent doing the spending.
    /// @param amount Amount spent, in 6-decimal USDC units. Zero is allowed and counts as a tx.
    function consume(address agent, uint256 amount) external {
        if (!_authorizedProtocols[msg.sender]) revert NotAuthorizedProtocol(msg.sender);

        AgentConfig storage c = _configs[agent];
        if (!c.registered) return;

        if (block.timestamp >= uint256(c.sessionStart) + uint256(c.sessionDuration)) {
            _rollSession(c, agent);
        }

        if (c.killed) revert AgentIsKilled(agent);
        if (c.paused) revert AgentIsPaused(agent);

        uint256 limit = uint256(c.spendingLimit);
        uint256 spent = uint256(c.spent);
        uint256 newSpent = spent + amount;
        if (newSpent > limit) {
            // `setLimits` can lower the limit below the amount already spent, so the headroom is
            // clamped at zero instead of underflowing.
            revert SpendingLimitExceeded(agent, amount, limit > spent ? limit - spent : 0);
        }
        if (c.txLimit != 0 && uint256(c.txCount) + 1 > uint256(c.txLimit)) {
            revert TxLimitExceeded(agent, c.txLimit);
        }

        // safe: newSpent <= spendingLimit, which is itself a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        c.spent = uint128(newSpent);
        c.txCount += 1;

        emit SpendConsumed(agent, msg.sender, amount);
    }

    // ─── Owner ──────────────────────────────────────────────────────────

    /// @notice Allow `protocol` to call `consume`.
    /// @param protocol Protocol contract to authorize.
    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);
        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    /// @notice Stop `protocol` from calling `consume`.
    /// @param protocol Protocol contract to revoke.
    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocols[protocol]) revert NotAuthorized(protocol);
        _authorizedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @notice Whether `agent` is neither killed nor paused. Unregistered agents are active.
    /// @param agent Agent to query.
    /// @return True when the agent may spend.
    function isActive(address agent) external view returns (bool) {
        AgentConfig storage c = _configs[agent];
        return !c.killed && !c.paused;
    }

    /// @notice Stored configuration for `agent`, exactly as held in storage.
    /// @param agent Agent to query.
    /// @return The agent configuration struct.
    function getConfig(address agent) external view returns (AgentConfig memory) {
        return _configs[agent];
    }

    /// @notice Spend still available to `agent` in its current session.
    /// @dev Unregistered agents have no limit; an expired session reports the full limit. Returns 0
    ///      rather than reverting when `setLimits` has lowered the limit below the amount spent.
    /// @param agent Agent to query.
    /// @return Remaining spendable amount in 6-decimal USDC units.
    function remainingSpend(address agent) external view returns (uint256) {
        AgentConfig storage c = _configs[agent];
        if (!c.registered) return type(uint256).max;
        if (block.timestamp >= uint256(c.sessionStart) + uint256(c.sessionDuration)) return c.spendingLimit;
        uint256 limit = uint256(c.spendingLimit);
        uint256 spent = uint256(c.spent);
        return limit > spent ? limit - spent : 0;
    }

    /// @notice Guardian currently set for `agent`, or the zero address when none is set.
    /// @param agent Agent to query.
    /// @return The guardian address.
    function guardianOf(address agent) external view returns (address) {
        return _guardians[agent];
    }

    /// @notice Whether `protocol` may call `consume`.
    /// @param protocol Protocol address to query.
    /// @return True when authorized.
    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _requireRegistered(address agent) private view {
        if (!_configs[agent].registered) revert NotRegistered(agent);
    }

    function _requirePrincipalOrGuardian(address agent) private view {
        if (msg.sender != agent && msg.sender != _guardians[agent]) revert NotPrincipalOrGuardian(agent, msg.sender);
    }

    /// @dev uint48 holds timestamps far beyond any realistic chain lifetime.
    // forge-lint: disable-next-line(unsafe-typecast)
    function _now() private view returns (uint48) {
        return uint48(block.timestamp);
    }

    function _validateDuration(uint48 d) private pure {
        if (d < MIN_SESSION_DURATION || d > MAX_SESSION_DURATION) revert InvalidSessionDuration(d);
    }

    function _rollSession(AgentConfig storage c, address agent) private {
        uint48 startedAt = _now();
        c.spent = 0;
        c.txCount = 0;
        c.sessionStart = startedAt;
        emit SessionReset(agent, startedAt);
    }
}
