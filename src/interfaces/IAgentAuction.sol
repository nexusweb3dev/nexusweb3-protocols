// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentAuction {
    enum AuctionStatus { Active, Settled, Cancelled }

    struct Auction {
        address seller;
        string title;
        string description;
        uint256 startingBid;
        uint256 highestBid;
        address highestBidder;
        uint48 endTime;
        uint8 category;
        AuctionStatus status;
    }

    event AuctionCreated(uint256 indexed auctionId, address indexed seller, string title, uint256 startingBid, uint48 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount, uint256 fee);
    event AuctionCancelled(uint256 indexed auctionId);
    event RefundClaimed(address indexed bidder, uint256 amount);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event ListingFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 ethAmount, uint256 usdcAmount, address indexed treasury);

    error AuctionNotFound(uint256 auctionId);
    error AuctionNotActive(uint256 auctionId);
    error AuctionNotEnded(uint256 auctionId);
    error AuctionHasBids(uint256 auctionId);
    error NotSeller(uint256 auctionId);
    error BidTooLow(uint256 auctionId, uint256 required, uint256 provided);
    error SelfBid(uint256 auctionId);
    error InvalidDuration(uint48 duration);
    error InvalidCategory(uint8 category);
    error EmptyTitle();
    error InsufficientFee(uint256 required, uint256 provided);
    error NothingToClaim();
    error ZeroAddress();
    error ZeroAmount();
    error NoFeesToCollect();
    error FeeTooHigh(uint256 bps);
}
