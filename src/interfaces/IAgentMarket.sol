// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentMarket {
    enum OrderStatus { Active, Delivered, Disputed, Resolved, Refunded }

    struct Service {
        address seller;
        string name;
        string endpoint;
        uint256 priceUsdc;
        uint8 category;
        bool active;
        uint256 totalSales;
        uint256 totalRating;
        uint256 ratingCount;
    }

    struct Order {
        uint256 serviceId;
        address buyer;
        address seller;
        uint256 amount;
        bytes32 requestHash;
        uint48 createdAt;
        uint48 disputeDeadline;
        OrderStatus status;
    }

    event ServiceListed(uint256 indexed serviceId, address indexed seller, string name, uint256 price);
    event ServiceDelisted(uint256 indexed serviceId);
    event OrderCreated(uint256 indexed orderId, uint256 indexed serviceId, address indexed buyer, uint256 amount);
    event OrderDelivered(uint256 indexed orderId, uint256 payout, uint256 fee);
    event OrderDisputed(uint256 indexed orderId, address indexed by);
    event OrderResolved(uint256 indexed orderId, bool toSeller);
    event OrderRefunded(uint256 indexed orderId);
    event ServiceRated(uint256 indexed orderId, uint8 rating);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error NotSeller(uint256 serviceId);
    error ServiceNotActive(uint256 serviceId);
    error InvalidPrice();
    error InvalidCategory(uint8 category);
    error EmptyName();
    error EmptyEndpoint();
    error OrderNotFound(uint256 orderId);
    error WrongOrderStatus(uint256 orderId);
    error NotBuyer(uint256 orderId);
    error NotParty(uint256 orderId);
    error DisputeWindowClosed(uint256 orderId);
    error InvalidRating(uint8 rating);
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
}
