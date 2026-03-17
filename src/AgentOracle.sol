// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentOracle} from "./interfaces/IAgentOracle.sol";

/// @notice Price and data feed aggregator for AI agents. Publishers push data, agents query at micro-cost.
contract AgentOracle is Ownable, ReentrancyGuard, Pausable, IAgentOracle {
    using SafeERC20 for IERC20;

    uint256 public constant STALENESS_THRESHOLD = 1 hours;
    uint256 public constant MAX_MONTHS = 12;
    uint256 public constant MONTH = 30 days;

    IERC20 public immutable paymentToken;

    uint256 public queryFee;
    uint256 public subscriptionPrice;
    address public treasury;
    uint256 public accumulatedEthFees;
    uint256 public accumulatedUsdcFees;

    mapping(bytes32 => FeedData) private _feeds;
    mapping(bytes32 => bool) private _feedExists;
    mapping(address => bool) private _publishers;
    mapping(address => mapping(bytes32 => uint48)) private _subscriptions;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 queryFee_,
        uint256 subscriptionPrice_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        paymentToken = paymentToken_;
        treasury = treasury_;
        queryFee = queryFee_;
        subscriptionPrice = subscriptionPrice_;
    }

    // ─── Publisher: Update Feed ─────────────────────────────────────────

    /// @notice Push a new value for a feed. Only authorized publishers.
    function updateFeed(bytes32 feedId, uint256 value, uint48 timestamp) external whenNotPaused {
        if (!_publishers[msg.sender]) revert NotPublisher(msg.sender);
        if (value == 0) revert ZeroValue();
        if (timestamp > uint48(block.timestamp)) revert StaleTimestamp(timestamp, uint48(block.timestamp));

        _feeds[feedId] = FeedData({value: value, updatedAt: timestamp, publisher: msg.sender});
        _feedExists[feedId] = true;

        emit FeedUpdated(feedId, value, timestamp, msg.sender);
    }

    // ─── Query: Get Value ───────────────────────────────────────────────

    /// @notice Get latest value for a feed. Free view — no on-chain proof.
    function getLatestValueFree(bytes32 feedId) external view returns (uint256 value, uint48 updatedAt, bool isStale) {
        if (!_feedExists[feedId]) revert FeedNotFound(feedId);
        FeedData storage fd = _feeds[feedId];
        bool stale = (uint48(block.timestamp) - fd.updatedAt) > uint48(STALENESS_THRESHOLD);
        return (fd.value, fd.updatedAt, stale);
    }

    /// @notice Get latest value with on-chain verifiable call. Costs queryFee or free for subscribers.
    function getLatestValue(bytes32 feedId) external payable returns (uint256 value, uint48 updatedAt, bool isStale) {
        if (!_feedExists[feedId]) revert FeedNotFound(feedId);

        if (_subscriptions[msg.sender][feedId] < uint48(block.timestamp)) {
            if (msg.value < queryFee) revert InsufficientFee(queryFee, msg.value);
            accumulatedEthFees += msg.value;
        }

        FeedData storage fd = _feeds[feedId];
        bool stale = (uint48(block.timestamp) - fd.updatedAt) > uint48(STALENESS_THRESHOLD);
        return (fd.value, fd.updatedAt, stale);
    }

    // ─── Subscription ───────────────────────────────────────────────────

    /// @notice Subscribe to a feed for unlimited on-chain queries.
    function subscribe(bytes32 feedId, uint256 months) external nonReentrant whenNotPaused {
        if (months == 0 || months > MAX_MONTHS) revert InvalidMonths();
        if (!_feedExists[feedId]) revert FeedNotFound(feedId);

        uint256 cost = subscriptionPrice * months;
        uint48 currentEnd = _subscriptions[msg.sender][feedId];
        uint48 now_ = uint48(block.timestamp);
        uint48 base = currentEnd > now_ ? currentEnd : now_;
        uint48 newEnd = base + uint48(months * MONTH);

        _subscriptions[msg.sender][feedId] = newEnd;
        accumulatedUsdcFees += cost;

        paymentToken.safeTransferFrom(msg.sender, address(this), cost);

        emit SubscriptionCreated(msg.sender, feedId, newEnd);
    }

    /// @notice Check if an address is subscribed to a feed.
    function isSubscribed(address caller, bytes32 feedId) external view returns (bool) {
        return _subscriptions[caller][feedId] >= uint48(block.timestamp);
    }

    /// @notice Get subscription expiry for an address and feed.
    function getSubscriptionExpiry(address caller, bytes32 feedId) external view returns (uint48) {
        return _subscriptions[caller][feedId];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect accumulated fees to treasury.
    function collectFees() external nonReentrant {
        uint256 ethAmt = accumulatedEthFees;
        uint256 usdcAmt = accumulatedUsdcFees;
        if (ethAmt == 0 && usdcAmt == 0) revert NoFeesToCollect();

        accumulatedEthFees = 0;
        accumulatedUsdcFees = 0;

        if (ethAmt > 0) {
            (bool ok,) = treasury.call{value: ethAmt}("");
            require(ok, "ETH transfer failed");
        }
        if (usdcAmt > 0) {
            paymentToken.safeTransfer(treasury, usdcAmt);
        }

        emit FeesCollected(ethAmt, usdcAmt, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /// @notice Authorize an address to publish feed data.
    function authorizePublisher(address publisher) external onlyOwner {
        if (publisher == address(0)) revert ZeroAddress();
        if (_publishers[publisher]) revert AlreadyPublisher(publisher);
        _publishers[publisher] = true;
        emit PublisherAuthorized(publisher);
    }

    /// @notice Revoke a publisher's authorization.
    function revokePublisher(address publisher) external onlyOwner {
        if (!_publishers[publisher]) revert NotAuthorizedPublisher(publisher);
        _publishers[publisher] = false;
        emit PublisherRevoked(publisher);
    }

    function setQueryFee(uint256 newFee) external onlyOwner {
        uint256 old = queryFee;
        queryFee = newFee;
        emit QueryFeeUpdated(old, newFee);
    }

    function setSubscriptionPrice(uint256 newPrice) external onlyOwner {
        uint256 old = subscriptionPrice;
        subscriptionPrice = newPrice;
        emit SubscriptionPriceUpdated(old, newPrice);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function isPublisher(address addr) external view returns (bool) {
        return _publishers[addr];
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
