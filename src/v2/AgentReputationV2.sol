// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentReputationV2} from "./interfaces/IAgentReputationV2.sol";

/// @title AgentReputationV2
/// @notice Value-weighted on-chain reputation for AI agents. Authorized protocols record interactions;
///         every read is a free `view` — no query fees, no ETH handling anywhere in this contract.
contract AgentReputationV2 is Ownable2Step, Pausable, IAgentReputationV2 {
    /// @notice Starting score for every agent, including agents never recorded.
    uint256 public constant BASE_SCORE = 100;
    /// @notice Points added per positive interaction.
    uint256 public constant POSITIVE_POINTS = 10;
    /// @notice Points subtracted per negative interaction.
    uint256 public constant NEGATIVE_POINTS = 20;
    /// @notice USDC volume (6 decimals) that earns one score point: $100.
    uint256 public constant VOLUME_UNIT = 100e6;
    /// @notice Highest valid category id (0 PAYMENT, 1 ESCROW, 2 YIELD, 3 INSURANCE, 4 GENERAL).
    uint8 public constant MAX_CATEGORY = 4;

    mapping(address => Stats) private _stats;
    mapping(address => bool) private _authorizedProtocols;

    /// @param owner_ Address receiving contract ownership.
    constructor(address owner_) Ownable(owner_) {}

    // ─── Record ─────────────────────────────────────────────────────────

    /// @notice Record an interaction for `agent`. Only authorized protocols, only while unpaused.
    /// @param agent Agent whose reputation is updated; must not be the zero address.
    /// @param positive True for a successful interaction, false for a failure.
    /// @param category Interaction category, 0..MAX_CATEGORY.
    /// @param valueUsdc Settled value in USDC (6 decimals); counted toward volume on positives only.
    function recordInteraction(address agent, bool positive, uint8 category, uint256 valueUsdc) external whenNotPaused {
        if (!_authorizedProtocols[msg.sender]) revert NotAuthorizedProtocol(msg.sender);
        if (agent == address(0)) revert ZeroAddress();
        if (category > MAX_CATEGORY) revert InvalidCategory(category);

        Stats storage s = _stats[agent];
        if (s.firstSeen == 0) s.firstSeen = uint48(block.timestamp);
        s.lastActivity = uint48(block.timestamp);

        if (positive) {
            s.positives += 1;
            uint128 current = s.volumeUsdc;
            uint256 headroom = uint256(type(uint128).max) - uint256(current);
            // casting to 'uint128' is safe because the branch requires valueUsdc < headroom <= uint128.max
            // forge-lint: disable-next-line(unsafe-typecast)
            s.volumeUsdc = valueUsdc >= headroom ? type(uint128).max : current + uint128(valueUsdc);
        } else {
            s.negatives += 1;
        }

        emit InteractionRecorded(agent, msg.sender, positive, category, valueUsdc);
    }

    // ─── Reads (always free) ────────────────────────────────────────────

    /// @notice Current reputation score, floored at 0. Unknown agents score BASE_SCORE.
    /// @param agent Agent to score.
    /// @return Reputation score.
    function getScore(address agent) public view returns (uint256) {
        Stats storage s = _stats[agent];
        uint256 gains = BASE_SCORE + POSITIVE_POINTS * uint256(s.positives) + uint256(s.volumeUsdc) / VOLUME_UNIT;
        uint256 losses = NEGATIVE_POINTS * uint256(s.negatives);
        return gains > losses ? gains - losses : 0;
    }

    /// @notice Tier derived from the score: PLATINUM >=1000, GOLD >=500, SILVER >=200, else BRONZE.
    /// @param agent Agent to classify.
    /// @return Reputation tier.
    function getTier(address agent) external view returns (Tier) {
        return _tierFromScore(getScore(agent));
    }

    /// @notice Raw counters for an agent. Unknown agents return a zeroed struct.
    /// @param agent Agent to inspect.
    /// @return Stats struct for the agent.
    function getStats(address agent) external view returns (Stats memory) {
        return _stats[agent];
    }

    /// @notice Whether `protocol` may record interactions.
    /// @param protocol Address to check.
    /// @return True if authorized.
    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /// @notice Authorize a protocol to record interactions.
    /// @param protocol Address to authorize; must be non-zero and not already authorized.
    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);

        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    /// @notice Revoke a protocol's authorization.
    /// @param protocol Address to revoke; must currently be authorized.
    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocols[protocol]) revert NotAuthorized(protocol);

        _authorizedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    /// @notice Pause recording. Reads stay available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume recording.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _tierFromScore(uint256 score) internal pure returns (Tier) {
        if (score >= 1000) return Tier.PLATINUM;
        if (score >= 500) return Tier.GOLD;
        if (score >= 200) return Tier.SILVER;
        return Tier.BRONZE;
    }
}
