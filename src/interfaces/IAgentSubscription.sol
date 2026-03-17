// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentSubscription {
    struct Plan {
        address provider;
        string name;
        uint256 price;
        uint48 interval;
        uint256 maxSubscribers;
        uint256 subscriberCount;
        bool active;
    }

    struct Subscription {
        address subscriber;
        uint256 planId;
        uint256 lockedPrice;
        uint48 nextPaymentDue;
        uint48 paidUntil;
        bool active;
    }

    event PlanCreated(uint256 indexed planId, address indexed provider, string name, uint256 price, uint48 interval);
    event PlanPaused(uint256 indexed planId);
    event PlanResumed(uint256 indexed planId);
    event Subscribed(uint256 indexed subscriptionId, address indexed subscriber, uint256 indexed planId, uint48 paidUntil);
    event RenewalProcessed(uint256 indexed subscriptionId, address indexed keeper, uint256 payment);
    event SubscriptionCancelled(uint256 indexed subscriptionId);
    event SubscriptionExpired(uint256 indexed subscriptionId);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error PlanNotFound(uint256 planId);
    error PlanNotActive(uint256 planId);
    error PlanFull(uint256 planId);
    error SubscriptionNotFound(uint256 subscriptionId);
    error SubscriptionNotActive(uint256 subscriptionId);
    error NotSubscriber(uint256 subscriptionId);
    error NotProvider(uint256 planId);
    error RenewalNotDue(uint256 subscriptionId, uint48 nextDue);
    error InvalidInterval();
    error InvalidPrice();
    error InvalidMonths();
    error EmptyName();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NoFeesToCollect();
}
