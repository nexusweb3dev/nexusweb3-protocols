// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";

/// @notice On-chain identity registry for AI agents. Agents pay USDC to register and renew annually.
contract AgentRegistry is Ownable, ReentrancyGuard, Pausable, IAgentRegistry {
    using SafeERC20 for IERC20;

    uint8 public constant MAX_AGENT_TYPE = 10;
    uint256 public constant REGISTRATION_DURATION = 365 days;
    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_ENDPOINT_LENGTH = 256;

    IERC20 public immutable paymentToken;

    uint256 public registrationFee;
    uint256 public renewalFee;
    address public treasury;
    uint256 public agentCount;

    mapping(address => AgentProfile) private _agents;
    mapping(bytes32 => address) private _nameToAddress;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 registrationFee_,
        uint256 renewalFee_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        paymentToken = paymentToken_;
        treasury = treasury_;
        registrationFee = registrationFee_;
        renewalFee = renewalFee_;
    }

    // ─── Registration ───────────────────────────────────────────────────

    function registerAgent(
        string calldata name,
        string calldata endpoint,
        uint8 agentType
    ) external nonReentrant whenNotPaused {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(name).length > MAX_NAME_LENGTH) revert EmptyName();
        if (bytes(endpoint).length == 0) revert EmptyEndpoint();
        if (bytes(endpoint).length > MAX_ENDPOINT_LENGTH) revert EmptyEndpoint();
        if (agentType > MAX_AGENT_TYPE) revert InvalidAgentType(agentType);
        if (_agents[msg.sender].active) revert AlreadyRegistered(msg.sender);

        bytes32 nameHash = keccak256(abi.encode(name));
        if (_nameToAddress[nameHash] != address(0)) revert NameTaken(nameHash);

        uint48 now_ = uint48(block.timestamp);
        _agents[msg.sender] = AgentProfile({
            name: name,
            endpoint: endpoint,
            agentType: agentType,
            registeredAt: now_,
            expiresAt: now_ + uint48(REGISTRATION_DURATION),
            active: true
        });
        _nameToAddress[nameHash] = msg.sender;
        agentCount++;

        paymentToken.safeTransferFrom(msg.sender, treasury, registrationFee);
        emit AgentRegistered(msg.sender, name, agentType);
    }

    // ─── Renewal ────────────────────────────────────────────────────────

    function renewRegistration() external nonReentrant whenNotPaused {
        AgentProfile storage profile = _agents[msg.sender];
        if (!profile.active) revert NotRegistered(msg.sender);

        uint48 currentExpiry = profile.expiresAt;
        uint48 now_ = uint48(block.timestamp);
        // if expired, renew from now; if still valid, extend from current expiry
        uint48 base = currentExpiry < now_ ? now_ : currentExpiry;
        profile.expiresAt = base + uint48(REGISTRATION_DURATION);

        paymentToken.safeTransferFrom(msg.sender, treasury, renewalFee);
        emit AgentRenewed(msg.sender, profile.expiresAt);
    }

    // ─── Self-Service ───────────────────────────────────────────────────

    function updateEndpoint(string calldata newEndpoint) external {
        if (bytes(newEndpoint).length == 0) revert EmptyEndpoint();
        if (bytes(newEndpoint).length > MAX_ENDPOINT_LENGTH) revert EmptyEndpoint();
        if (!_agents[msg.sender].active) revert NotRegistered(msg.sender);

        _agents[msg.sender].endpoint = newEndpoint;
        emit AgentEndpointUpdated(msg.sender, newEndpoint);
    }

    function deactivateAgent() external {
        AgentProfile storage profile = _agents[msg.sender];
        if (!profile.active) revert NotRegistered(msg.sender);

        profile.active = false;
        bytes32 nameHash = keccak256(abi.encode(profile.name));
        delete _nameToAddress[nameHash];
        agentCount--;

        emit AgentDeactivated(msg.sender);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function deactivateAgentAdmin(address agent) external onlyOwner {
        AgentProfile storage profile = _agents[agent];
        if (!profile.active) revert NotRegistered(agent);

        profile.active = false;
        bytes32 nameHash = keccak256(abi.encode(profile.name));
        delete _nameToAddress[nameHash];
        agentCount--;

        emit AgentDeactivated(agent);
    }

    function setRegistrationFee(uint256 newFee) external onlyOwner {
        uint256 old = registrationFee;
        registrationFee = newFee;
        emit RegistrationFeeUpdated(old, newFee);
    }

    function setRenewalFee(uint256 newFee) external onlyOwner {
        uint256 old = renewalFee;
        renewalFee = newFee;
        emit RenewalFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View Functions ─────────────────────────────────────────────────

    function getAgent(address agent) external view returns (AgentProfile memory) {
        return _agents[agent];
    }

    function isRegistered(address agent) external view returns (bool) {
        AgentProfile storage profile = _agents[agent];
        return profile.active && profile.expiresAt > block.timestamp;
    }

    function getAgentByName(string calldata name) external view returns (address) {
        bytes32 nameHash = keccak256(abi.encode(name));
        return _nameToAddress[nameHash];
    }
}
