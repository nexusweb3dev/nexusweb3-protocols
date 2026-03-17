// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentOracle {
    struct FeedData {
        uint256 value;
        uint48 updatedAt;
        address publisher;
    }

    event FeedUpdated(bytes32 indexed feedId, uint256 value, uint48 timestamp, address indexed publisher);
    event SubscriptionCreated(address indexed subscriber, bytes32 indexed feedId, uint48 expiresAt);
    event PublisherAuthorized(address indexed publisher);
    event PublisherRevoked(address indexed publisher);
    event QueryFeeUpdated(uint256 oldFee, uint256 newFee);
    event SubscriptionPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 ethAmount, uint256 usdcAmount, address indexed treasury);

    error NotPublisher(address caller);
    error AlreadyPublisher(address publisher);
    error NotAuthorizedPublisher(address publisher);
    error FeedNotFound(bytes32 feedId);
    error StaleTimestamp(uint48 provided, uint48 current);
    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidMonths();
    error ZeroAddress();
    error ZeroValue();
    error NoFeesToCollect();
}
