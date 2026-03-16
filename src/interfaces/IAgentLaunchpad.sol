// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentLaunchpad {
    struct Protocol {
        address deployer;
        address contractAddress;
        string name;
        uint8 category;
        uint48 launchedAt;
        bool verified;
        bool revoked;
    }

    event ProtocolLaunched(uint256 indexed id, address indexed deployer, address indexed contractAddr, string name);
    event ProtocolVerified(uint256 indexed id);
    event ProtocolRevoked(uint256 indexed id);
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidCategory(uint8 category);
    error EmptyName();
    error ProtocolNotFound(uint256 id);
    error AlreadyVerified(uint256 id);
    error AlreadyRevoked(uint256 id);
    error MaxProtocolsPerDeployer(address deployer);
    error ZeroAddress();
    error NoFeesToCollect();
}
