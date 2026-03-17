// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentWhitelist {
    struct Whitelist {
        address listOwner;
        address pendingOwner;
        string name;
        bool requireRegistered;
        uint256 minReputation;
        uint256 agentCount;
        bool active;
    }

    event WhitelistCreated(uint256 indexed whitelistId, address indexed listOwner, string name);
    event AgentAdded(uint256 indexed whitelistId, address indexed agent);
    event AgentRemoved(uint256 indexed whitelistId, address indexed agent);
    event OwnershipOffered(uint256 indexed whitelistId, address indexed newOwner);
    event OwnershipAccepted(uint256 indexed whitelistId, address indexed newOwner);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error NotWhitelistOwner(uint256 whitelistId);
    error WhitelistNotFound(uint256 whitelistId);
    error AgentAlreadyWhitelisted(uint256 whitelistId, address agent);
    error AgentNotWhitelisted(uint256 whitelistId, address agent);
    error NotPendingOwner(uint256 whitelistId);
    error EmptyName();
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
}
