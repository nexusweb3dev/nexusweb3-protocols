// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentBridge} from "./interfaces/IAgentBridge.sol";

/// @notice Cross-chain identity portability for AI agents. One identity — all chains.
contract AgentBridge is Ownable, ReentrancyGuard, Pausable, IAgentBridge {
    uint256 public bridgeFee;
    address public treasury;
    address public relayer;
    uint256 public accumulatedFees;

    mapping(uint256 => bool) public supportedChains;
    mapping(address => mapping(uint256 => bool)) private _bridgedTo; // agent => chainId => bridged
    mapping(address => mapping(uint256 => bool)) private _verifiedFrom; // agent => sourceChainId => verified
    mapping(address => bytes32) private _identityHashes;

    constructor(address treasury_, address relayer_, address owner_, uint256 bridgeFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (relayer_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        relayer = relayer_;
        bridgeFee = bridgeFee_;

        supportedChains[8453] = true;   // Base
        supportedChains[42161] = true;  // Arbitrum
        supportedChains[10] = true;     // Optimism
        supportedChains[137] = true;    // Polygon
        supportedChains[56] = true;     // BNB
    }

    /// @notice Register agent identity for cross-chain bridging. Pays bridge fee.
    function registerCrossChain(uint256 targetChainId) external payable nonReentrant whenNotPaused {
        if (!supportedChains[targetChainId]) revert UnsupportedChain(targetChainId);
        if (_bridgedTo[msg.sender][targetChainId]) revert AlreadyBridged(msg.sender, targetChainId);
        if (msg.value < bridgeFee) revert InsufficientFee(bridgeFee, msg.value);

        bytes32 idHash = keccak256(abi.encode(msg.sender, block.chainid));
        _identityHashes[msg.sender] = idHash;
        _bridgedTo[msg.sender][targetChainId] = true;
        accumulatedFees += msg.value;

        emit CrossChainRegistered(msg.sender, targetChainId, idHash);
    }

    /// @notice Relayer verifies agent identity from another chain.
    function verifyFromBridge(address agent, bytes32 identityHash, uint256 sourceChainId) external whenNotPaused {
        if (msg.sender != relayer) revert NotRelayer(msg.sender);
        if (!supportedChains[sourceChainId]) revert UnsupportedChain(sourceChainId);
        if (_verifiedFrom[agent][sourceChainId]) revert AlreadyVerified(agent, sourceChainId);

        _verifiedFrom[agent][sourceChainId] = true;
        _identityHashes[agent] = identityHash;

        emit IdentityVerified(agent, sourceChainId, identityHash);
    }

    /// @notice Check if agent identity is verified from a specific chain.
    function isVerifiedFromChain(address agent, uint256 sourceChainId) external view returns (bool) {
        return _verifiedFrom[agent][sourceChainId];
    }

    /// @notice Check if agent has bridged to a specific chain.
    function isBridgedTo(address agent, uint256 targetChainId) external view returns (bool) {
        return _bridgedTo[agent][targetChainId];
    }

    /// @notice Get identity hash for an agent.
    function getIdentityHash(address agent) external view returns (bytes32) {
        return _identityHashes[agent];
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

    function addChain(uint256 chainId) external onlyOwner {
        if (supportedChains[chainId]) revert ChainAlreadySupported(chainId);
        supportedChains[chainId] = true;
        emit ChainAdded(chainId);
    }

    function removeChain(uint256 chainId) external onlyOwner {
        if (!supportedChains[chainId]) revert ChainNotSupported(chainId);
        supportedChains[chainId] = false;
        emit ChainRemoved(chainId);
    }

    function setRelayer(address newRelayer) external onlyOwner {
        if (newRelayer == address(0)) revert ZeroAddress();
        address old = relayer;
        relayer = newRelayer;
        emit RelayerUpdated(old, newRelayer);
    }

    function setBridgeFee(uint256 newFee) external onlyOwner {
        uint256 old = bridgeFee;
        bridgeFee = newFee;
        emit BridgeFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
