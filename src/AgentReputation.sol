// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentReputation} from "./interfaces/IAgentReputation.sol";

/// @notice On-chain reputation scoring for AI agents. Authorized protocols record interactions.
contract AgentReputation is Ownable, ReentrancyGuard, Pausable, IAgentReputation {
    uint256 public constant BASE_SCORE = 100;
    uint256 public constant POSITIVE_POINTS = 10;
    uint256 public constant NEGATIVE_POINTS = 20;
    uint8 public constant MAX_CATEGORY = 4; // 0-4: PAYMENT, ESCROW, YIELD, INSURANCE, GENERAL

    uint256 public queryFee;
    address public treasury;
    uint256 public accumulatedFees;

    mapping(address => uint256) private _scores;
    mapping(address => bool) private _initialized;
    mapping(address => bool) private _authorizedProtocols;

    constructor(address treasury_, address owner_, uint256 queryFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        queryFee = queryFee_;
    }

    // ─── Record Interaction (authorized protocols only) ─────────────────

    /// @notice Record a positive or negative interaction for an agent. Only authorized protocols can call.
    function recordInteraction(address agent, bool positive, uint8 category) external whenNotPaused {
        if (!_authorizedProtocols[msg.sender]) revert NotAuthorizedProtocol(msg.sender);
        if (category > MAX_CATEGORY) revert InvalidCategory(category);
        if (agent == address(0)) revert ZeroAddress();

        if (!_initialized[agent]) {
            _scores[agent] = BASE_SCORE;
            _initialized[agent] = true;
        }

        if (positive) {
            _scores[agent] += POSITIVE_POINTS;
        } else {
            uint256 current = _scores[agent];
            _scores[agent] = current > NEGATIVE_POINTS ? current - NEGATIVE_POINTS : 0;
        }

        emit InteractionRecorded(agent, msg.sender, positive, category);
    }

    // ─── Query (free for authorized, fee for external) ──────────────────

    /// @notice Get reputation score. Free for authorized protocols, costs queryFee for others.
    function getReputation(address agent) external payable returns (uint256) {
        if (!_authorizedProtocols[msg.sender]) {
            if (msg.value < queryFee) revert InsufficientFee(queryFee, msg.value);
            accumulatedFees += msg.value;
        }
        return _initialized[agent] ? _scores[agent] : BASE_SCORE;
    }

    /// @notice Get reputation tier. Free for authorized protocols, costs queryFee for others.
    function getReputationTier(address agent) external payable returns (Tier) {
        if (!_authorizedProtocols[msg.sender]) {
            if (msg.value < queryFee) revert InsufficientFee(queryFee, msg.value);
            accumulatedFees += msg.value;
        }
        uint256 score = _initialized[agent] ? _scores[agent] : BASE_SCORE;
        return _tierFromScore(score);
    }

    /// @notice Free view for anyone — no fee. Returns raw score.
    function getScoreFree(address agent) external view returns (uint256) {
        return _initialized[agent] ? _scores[agent] : BASE_SCORE;
    }

    /// @notice Free view for anyone — no fee. Returns tier.
    function getTierFree(address agent) external view returns (Tier) {
        uint256 score = _initialized[agent] ? _scores[agent] : BASE_SCORE;
        return _tierFromScore(score);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect accumulated query fees to treasury.
    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();

        accumulatedFees = 0;

        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /// @notice Authorize a protocol to record interactions (free queries).
    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocols[protocol]) revert AlreadyAuthorized(protocol);

        _authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    /// @notice Revoke a protocol's authorization.
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

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocols[protocol];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _tierFromScore(uint256 score) internal pure returns (Tier) {
        if (score >= 1000) return Tier.PLATINUM;
        if (score >= 500) return Tier.GOLD;
        if (score >= 200) return Tier.SILVER;
        return Tier.BRONZE;
    }
}
