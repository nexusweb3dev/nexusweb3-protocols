// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentWhitelist} from "./interfaces/IAgentWhitelist.sol";

/// @notice On-chain permission management for AI agent networks. Gate access by whitelist + reputation.
interface IRegistryCheck {
    function isRegistered(address agent) external view returns (bool);
}

interface IReputationCheck {
    function getScoreFree(address agent) external view returns (uint256);
}

contract AgentWhitelist is Ownable, ReentrancyGuard, Pausable, IAgentWhitelist {
    IRegistryCheck public immutable registry;
    IReputationCheck public immutable reputation;

    uint256 public creationFee;
    address public treasury;
    uint256 public whitelistCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Whitelist) private _whitelists;
    mapping(uint256 => mapping(address => bool)) private _manualWhitelist;

    constructor(
        address registry_,
        address reputation_,
        address treasury_,
        address owner_,
        uint256 creationFee_
    ) Ownable(owner_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (reputation_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        registry = IRegistryCheck(registry_);
        reputation = IReputationCheck(reputation_);
        treasury = treasury_;
        creationFee = creationFee_;
    }

    // ─── Create ─────────────────────────────────────────────────────────

    /// @notice Create a new whitelist with optional registration and reputation requirements.
    function createWhitelist(
        string calldata name,
        bool requireRegistered,
        uint256 minReputation
    ) external payable nonReentrant whenNotPaused returns (uint256 whitelistId) {
        if (bytes(name).length == 0) revert EmptyName();
        if (msg.value < creationFee) revert InsufficientFee(creationFee, msg.value);

        whitelistId = whitelistCount++;
        _whitelists[whitelistId] = Whitelist({
            listOwner: msg.sender,
            pendingOwner: address(0),
            name: name,
            requireRegistered: requireRegistered,
            minReputation: minReputation,
            agentCount: 0,
            active: true
        });
        accumulatedFees += msg.value;

        emit WhitelistCreated(whitelistId, msg.sender, name);
    }

    // ─── Manage Agents ──────────────────────────────────────────────────

    /// @notice Manually add an agent to a whitelist.
    function addAgent(uint256 whitelistId, address agent) external {
        Whitelist storage wl = _getWhitelist(whitelistId);
        if (wl.listOwner != msg.sender) revert NotWhitelistOwner(whitelistId);
        if (agent == address(0)) revert ZeroAddress();
        if (_manualWhitelist[whitelistId][agent]) revert AgentAlreadyWhitelisted(whitelistId, agent);

        _manualWhitelist[whitelistId][agent] = true;
        wl.agentCount++;

        emit AgentAdded(whitelistId, agent);
    }

    /// @notice Remove an agent from a whitelist.
    function removeAgent(uint256 whitelistId, address agent) external {
        Whitelist storage wl = _getWhitelist(whitelistId);
        if (wl.listOwner != msg.sender) revert NotWhitelistOwner(whitelistId);
        if (!_manualWhitelist[whitelistId][agent]) revert AgentNotWhitelisted(whitelistId, agent);

        _manualWhitelist[whitelistId][agent] = false;
        wl.agentCount--;

        emit AgentRemoved(whitelistId, agent);
    }

    // ─── Check ──────────────────────────────────────────────────────────

    /// @notice Check if an agent is whitelisted (manual list OR meets auto-qualification).
    function isWhitelisted(uint256 whitelistId, address agent) external view returns (bool) {
        if (whitelistId >= whitelistCount) return false;
        Whitelist storage wl = _whitelists[whitelistId];

        // manually whitelisted always passes
        if (_manualWhitelist[whitelistId][agent]) return true;

        // auto-qualification: check registration + reputation
        if (wl.requireRegistered) {
            try registry.isRegistered(agent) returns (bool registered) {
                if (!registered) return false;
            } catch {
                return false;
            }
        }

        if (wl.minReputation > 0) {
            try reputation.getScoreFree(agent) returns (uint256 score) {
                if (score < wl.minReputation) return false;
            } catch {
                return false;
            }
        }

        // if no auto-qualification rules set and not manually added
        if (!wl.requireRegistered && wl.minReputation == 0) return false;

        return true;
    }

    // ─── Ownership Transfer (two-step) ──────────────────────────────────

    /// @notice Offer whitelist ownership to a new address.
    function transferWhitelistOwnership(uint256 whitelistId, address newOwner) external {
        Whitelist storage wl = _getWhitelist(whitelistId);
        if (wl.listOwner != msg.sender) revert NotWhitelistOwner(whitelistId);
        if (newOwner == address(0)) revert ZeroAddress();

        wl.pendingOwner = newOwner;
        emit OwnershipOffered(whitelistId, newOwner);
    }

    /// @notice Accept whitelist ownership transfer.
    function acceptWhitelistOwnership(uint256 whitelistId) external {
        Whitelist storage wl = _getWhitelist(whitelistId);
        if (wl.pendingOwner != msg.sender) revert NotPendingOwner(whitelistId);

        wl.listOwner = msg.sender;
        wl.pendingOwner = address(0);
        emit OwnershipAccepted(whitelistId, msg.sender);
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

    function setCreationFee(uint256 newFee) external onlyOwner {
        uint256 old = creationFee;
        creationFee = newFee;
        emit CreationFeeUpdated(old, newFee);
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

    function getWhitelist(uint256 whitelistId) external view returns (Whitelist memory) {
        if (whitelistId >= whitelistCount) revert WhitelistNotFound(whitelistId);
        return _whitelists[whitelistId];
    }

    function isManuallyWhitelisted(uint256 whitelistId, address agent) external view returns (bool) {
        return _manualWhitelist[whitelistId][agent];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getWhitelist(uint256 whitelistId) internal view returns (Whitelist storage) {
        if (whitelistId >= whitelistCount) revert WhitelistNotFound(whitelistId);
        return _whitelists[whitelistId];
    }
}
