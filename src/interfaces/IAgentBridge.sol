// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentBridge {
    event CrossChainRegistered(address indexed agent, uint256 indexed targetChainId, bytes32 identityHash);
    event IdentityVerified(address indexed agent, uint256 indexed sourceChainId, bytes32 identityHash);
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event ChainAdded(uint256 chainId);
    event ChainRemoved(uint256 chainId);
    event BridgeFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error UnsupportedChain(uint256 chainId);
    error AlreadyBridged(address agent, uint256 chainId);
    error AlreadyVerified(address agent, uint256 sourceChainId);
    error NotRelayer(address caller);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
    error ChainAlreadySupported(uint256 chainId);
    error ChainNotSupported(uint256 chainId);
}
