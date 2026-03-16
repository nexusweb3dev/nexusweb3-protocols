// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentReputation {
    enum Tier { BRONZE, SILVER, GOLD, PLATINUM }

    event InteractionRecorded(address indexed agent, address indexed recorder, bool positive, uint8 category);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);
    event QueryFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error InvalidCategory(uint8 category);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();

    function recordInteraction(address agent, bool positive, uint8 category) external;
    function getReputation(address agent) external payable returns (uint256);
    function getReputationTier(address agent) external payable returns (Tier);
    function isAuthorizedProtocol(address protocol) external view returns (bool);
    function queryFee() external view returns (uint256);
    function treasury() external view returns (address);
}
