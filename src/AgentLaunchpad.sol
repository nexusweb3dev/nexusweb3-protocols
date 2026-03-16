// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentLaunchpad} from "./interfaces/IAgentLaunchpad.sol";

/// @notice Protocol launchpad for the AI agent economy. Developers deploy protocols and pay launch fee.
contract AgentLaunchpad is Ownable, ReentrancyGuard, Pausable, IAgentLaunchpad {
    uint8 public constant MAX_CATEGORY = 4; // DEFI, SECURITY, DATA, SOCIAL, GAMING
    uint256 public constant MAX_PROTOCOLS_PER_DEPLOYER = 20;

    uint256 public launchFee;
    address public treasury;
    uint256 public protocolCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Protocol) private _protocols;
    mapping(address => uint256) private _deployerProtocolCount;

    constructor(address treasury_, address owner_, uint256 launchFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        launchFee = launchFee_;
    }

    /// @notice Register a deployed protocol on the launchpad.
    function launchProtocol(
        address contractAddr,
        string calldata name,
        uint8 category
    ) external payable nonReentrant whenNotPaused {
        if (contractAddr == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (category > MAX_CATEGORY) revert InvalidCategory(category);
        if (msg.value < launchFee) revert InsufficientFee(launchFee, msg.value);
        if (_deployerProtocolCount[msg.sender] >= MAX_PROTOCOLS_PER_DEPLOYER) {
            revert MaxProtocolsPerDeployer(msg.sender);
        }

        uint256 id = protocolCount++;
        _protocols[id] = Protocol({
            deployer: msg.sender,
            contractAddress: contractAddr,
            name: name,
            category: category,
            launchedAt: uint48(block.timestamp),
            verified: false,
            revoked: false
        });
        _deployerProtocolCount[msg.sender]++;
        accumulatedFees += msg.value;

        emit ProtocolLaunched(id, msg.sender, contractAddr, name);
    }

    /// @notice Owner marks a protocol as verified.
    function verifyProtocol(uint256 id) external onlyOwner {
        if (id >= protocolCount) revert ProtocolNotFound(id);
        Protocol storage p = _protocols[id];
        if (p.verified) revert AlreadyVerified(id);
        if (p.revoked) revert AlreadyRevoked(id);
        p.verified = true;
        emit ProtocolVerified(id);
    }

    /// @notice Owner revokes a malicious protocol.
    function revokeProtocol(uint256 id) external onlyOwner {
        if (id >= protocolCount) revert ProtocolNotFound(id);
        Protocol storage p = _protocols[id];
        if (p.revoked) revert AlreadyRevoked(id);
        p.verified = false;
        p.revoked = true;
        emit ProtocolRevoked(id);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setLaunchFee(uint256 newFee) external onlyOwner {
        uint256 old = launchFee;
        launchFee = newFee;
        emit LaunchFeeUpdated(old, newFee);
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

    function getProtocol(uint256 id) external view returns (Protocol memory) {
        if (id >= protocolCount) revert ProtocolNotFound(id);
        return _protocols[id];
    }

    function getDeployerProtocolCount(address deployer) external view returns (uint256) {
        return _deployerProtocolCount[deployer];
    }
}
