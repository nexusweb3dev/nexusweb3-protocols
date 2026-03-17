// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentKillSwitch} from "./interfaces/IAgentKillSwitch.sol";

/// @notice Emergency stop for AI agents. Instant permission revocation. Zero delay kill switch.
contract AgentKillSwitch is Ownable, ReentrancyGuard, Pausable, IAgentKillSwitch {
    uint256 public registrationFee;
    address public treasury;
    uint256 public accumulatedFees;

    mapping(address => AgentConfig) private _agents;
    mapping(address => bool) private _registered;
    mapping(address => address) private _emergencyMultisig;
    mapping(address => KillEvent[]) private _killHistory;

    constructor(address treasury_, address owner_, uint256 registrationFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        registrationFee = registrationFee_;
    }

    // ─── Register ───────────────────────────────────────────────────────

    /// @notice Register an agent with hard spending and transaction limits.
    function registerAgent(
        address agent,
        uint256 spendingLimit,
        uint256 txLimit,
        uint48 sessionDuration
    ) external payable nonReentrant whenNotPaused {
        if (agent == address(0)) revert ZeroAddress();
        if (_registered[agent]) revert AgentAlreadyRegistered(agent);
        if (spendingLimit == 0 || txLimit == 0 || sessionDuration == 0) revert InvalidConfig();
        if (msg.value < registrationFee) revert InsufficientFee(registrationFee, msg.value);

        _agents[agent] = AgentConfig({
            agentOwner: msg.sender,
            spendingLimit: spendingLimit,
            spendingUsed: 0,
            txLimit: txLimit,
            txCount: 0,
            sessionStart: uint48(block.timestamp),
            sessionDuration: sessionDuration,
            active: true,
            paused: false
        });
        _registered[agent] = true;
        accumulatedFees += msg.value;

        emit AgentRegistered(agent, msg.sender, spendingLimit, txLimit);
    }

    // ─── Kill Switch (INSTANT — same block) ─────────────────────────────

    /// @notice Instantly and permanently revoke all agent permissions.
    function killSwitch(address agent) external nonReentrant {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (!c.active) revert AgentIsKilled(agent);

        // only owner or emergency multisig — NEVER the agent itself
        if (msg.sender == agent) revert AgentCannotKillItself(agent);
        if (msg.sender != c.agentOwner && msg.sender != _emergencyMultisig[agent]) {
            revert NotOwnerOrMultisig(agent, msg.sender);
        }

        c.active = false;
        c.paused = false;

        _killHistory[agent].push(KillEvent({
            timestamp: uint48(block.timestamp),
            killedBy: msg.sender
        }));

        emit AgentKilled(agent, msg.sender, uint48(block.timestamp));
    }

    // ─── Pause / Resume ─────────────────────────────────────────────────

    /// @notice Temporarily pause an agent. Can be resumed later.
    function pauseAgent(address agent) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (!c.active) revert AgentIsKilled(agent);

        if (msg.sender != c.agentOwner && msg.sender != _emergencyMultisig[agent]) {
            revert NotOwnerOrMultisig(agent, msg.sender);
        }

        c.paused = true;
        emit AgentPaused(agent, msg.sender);
    }

    /// @notice Resume a paused agent. Only owner (not multisig).
    function resumeAgent(address agent) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (!c.active) revert AgentIsKilled(agent);
        if (c.agentOwner != msg.sender) revert NotAgentOwner(agent, msg.sender);

        c.paused = false;
        emit AgentResumed(agent, msg.sender);
    }

    // ─── Session Management ─────────────────────────────────────────────

    /// @notice Reset session counters. Only owner.
    function resetSession(address agent) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (c.agentOwner != msg.sender) revert NotAgentOwner(agent, msg.sender);

        c.spendingUsed = 0;
        c.txCount = 0;
        c.sessionStart = uint48(block.timestamp);
        emit SessionReset(agent);
    }

    // ─── Emergency Multisig ─────────────────────────────────────────────

    /// @notice Set an emergency multisig that can also trigger killSwitch and pause.
    function setEmergencyMultisig(address agent, address multisig) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (c.agentOwner != msg.sender) revert NotAgentOwner(agent, msg.sender);

        address old = _emergencyMultisig[agent];
        _emergencyMultisig[agent] = multisig;
        emit EmergencyMultisigUpdated(agent, old, multisig);
    }

    // ─── Protocol Integration (called by other contracts) ───────────────

    /// @notice Check agent is active and decrement tx counter. Reverts if not allowed.
    function checkAndDecrementTx(address agent) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (!c.active) revert AgentIsKilled(agent);
        if (c.paused) revert AgentIsPaused(agent);

        // check session expiry
        if (uint48(block.timestamp) > c.sessionStart + c.sessionDuration) {
            revert SessionExpired(agent);
        }

        // check tx limit
        if (c.txCount >= c.txLimit) revert TxLimitExceeded(agent);
        c.txCount++;
    }

    /// @notice Check agent spending and record usage. Reverts if over limit.
    function checkAndDecrementSpending(address agent, uint256 amount) external {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        AgentConfig storage c = _agents[agent];
        if (!c.active) revert AgentIsKilled(agent);
        if (c.paused) revert AgentIsPaused(agent);

        if (uint48(block.timestamp) > c.sessionStart + c.sessionDuration) {
            revert SessionExpired(agent);
        }

        uint256 remaining = c.spendingLimit - c.spendingUsed;
        if (amount > remaining) revert SpendingLimitExceeded(agent, amount, remaining);
        c.spendingUsed += amount;
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

    function setRegistrationFee(uint256 newFee) external onlyOwner {
        uint256 old = registrationFee;
        registrationFee = newFee;
        emit RegistrationFeeUpdated(old, newFee);
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

    function isActive(address agent) external view returns (bool) {
        if (!_registered[agent]) return false;
        AgentConfig storage c = _agents[agent];
        return c.active && !c.paused;
    }

    function isSessionValid(address agent) external view returns (bool) {
        if (!_registered[agent]) return false;
        AgentConfig storage c = _agents[agent];
        if (!c.active || c.paused) return false;
        return uint48(block.timestamp) <= c.sessionStart + c.sessionDuration;
    }

    function getAgentConfig(address agent) external view returns (AgentConfig memory) {
        if (!_registered[agent]) revert AgentNotRegistered(agent);
        return _agents[agent];
    }

    function getKillHistory(address agent) external view returns (KillEvent[] memory) {
        return _killHistory[agent];
    }

    function getEmergencyMultisig(address agent) external view returns (address) {
        return _emergencyMultisig[agent];
    }
}
