// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentMarket} from "./interfaces/IAgentMarket.sol";

/// @notice Marketplace for AI agents to buy/sell services. 1% platform fee.
contract AgentMarket is Ownable, ReentrancyGuard, Pausable, IAgentMarket {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant DISPUTE_WINDOW = 1 days;
    uint256 public constant MIN_PRICE = 1_000_000; // $1 USDC
    uint8 public constant MAX_CATEGORY = 4; // DATA, SECURITY, TRADING, ANALYTICS, GENERAL

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public serviceCount;
    uint256 public orderCount;

    mapping(uint256 => Service) private _services;
    mapping(uint256 => Order) private _orders;

    constructor(IERC20 paymentToken_, address treasury_, address owner_, uint256 feeBps_) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = feeBps_;
    }

    /// @notice List a service for sale.
    function listService(string calldata name, string calldata endpoint, uint256 priceUsdc, uint8 category) external whenNotPaused {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(endpoint).length == 0) revert EmptyEndpoint();
        if (priceUsdc < MIN_PRICE) revert InvalidPrice();
        if (category > MAX_CATEGORY) revert InvalidCategory(category);

        uint256 id = serviceCount++;
        _services[id] = Service({
            seller: msg.sender, name: name, endpoint: endpoint, priceUsdc: priceUsdc,
            category: category, active: true, totalSales: 0, totalRating: 0, ratingCount: 0
        });
        emit ServiceListed(id, msg.sender, name, priceUsdc);
    }

    /// @notice Delist a service.
    function delistService(uint256 serviceId) external {
        Service storage s = _services[serviceId];
        if (s.seller != msg.sender) revert NotSeller(serviceId);
        s.active = false;
        emit ServiceDelisted(serviceId);
    }

    /// @notice Purchase a service. USDC held in escrow.
    function purchaseService(uint256 serviceId, bytes32 requestHash) external nonReentrant whenNotPaused {
        Service storage s = _services[serviceId];
        if (!s.active) revert ServiceNotActive(serviceId);

        uint256 orderId = orderCount++;
        uint48 now_ = uint48(block.timestamp);
        _orders[orderId] = Order({
            serviceId: serviceId, buyer: msg.sender, seller: s.seller, amount: s.priceUsdc,
            requestHash: requestHash, createdAt: now_, disputeDeadline: now_ + uint48(DISPUTE_WINDOW),
            status: OrderStatus.Active
        });

        paymentToken.safeTransferFrom(msg.sender, address(this), s.priceUsdc);
        emit OrderCreated(orderId, serviceId, msg.sender, s.priceUsdc);
    }

    /// @notice Buyer confirms delivery. Releases payment minus fee.
    function confirmDelivery(uint256 orderId) external nonReentrant {
        Order storage o = _getOrder(orderId);
        if (o.status != OrderStatus.Active) revert WrongOrderStatus(orderId);
        if (msg.sender != o.buyer) revert NotBuyer(orderId);

        o.status = OrderStatus.Delivered;
        _services[o.serviceId].totalSales++;

        uint256 fee = o.amount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 payout = o.amount - fee;

        if (fee > 0) paymentToken.safeTransfer(treasury, fee);
        paymentToken.safeTransfer(o.seller, payout);

        emit OrderDelivered(orderId, payout, fee);
    }

    /// @notice Dispute an order within dispute window.
    function disputeOrder(uint256 orderId) external {
        Order storage o = _getOrder(orderId);
        if (o.status != OrderStatus.Active) revert WrongOrderStatus(orderId);
        if (msg.sender != o.buyer && msg.sender != o.seller) revert NotParty(orderId);
        if (uint48(block.timestamp) > o.disputeDeadline) revert DisputeWindowClosed(orderId);

        o.status = OrderStatus.Disputed;
        emit OrderDisputed(orderId, msg.sender);
    }

    /// @notice Owner resolves dispute.
    function resolveDispute(uint256 orderId, bool toSeller) external onlyOwner nonReentrant {
        Order storage o = _getOrder(orderId);
        if (o.status != OrderStatus.Disputed) revert WrongOrderStatus(orderId);

        o.status = OrderStatus.Resolved;
        if (toSeller) {
            uint256 fee = o.amount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
            if (fee > 0) paymentToken.safeTransfer(treasury, fee);
            paymentToken.safeTransfer(o.seller, o.amount - fee);
        } else {
            paymentToken.safeTransfer(o.buyer, o.amount);
        }
        emit OrderResolved(orderId, toSeller);
    }

    /// @notice Auto-refund if dispute window passes and buyer hasn't confirmed.
    function refundOrder(uint256 orderId) external nonReentrant {
        Order storage o = _getOrder(orderId);
        if (o.status != OrderStatus.Active) revert WrongOrderStatus(orderId);
        if (uint48(block.timestamp) <= o.disputeDeadline) revert DisputeWindowClosed(orderId);

        o.status = OrderStatus.Refunded;
        paymentToken.safeTransfer(o.buyer, o.amount);
        emit OrderRefunded(orderId);
    }

    /// @notice Rate a completed service (1-5 stars).
    function rateService(uint256 orderId, uint8 rating) external {
        Order storage o = _getOrder(orderId);
        if (o.status != OrderStatus.Delivered) revert WrongOrderStatus(orderId);
        if (msg.sender != o.buyer) revert NotBuyer(orderId);
        if (rating < 1 || rating > 5) revert InvalidRating(rating);

        _services[o.serviceId].totalRating += rating;
        _services[o.serviceId].ratingCount++;
        emit ServiceRated(orderId, rating);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getService(uint256 serviceId) external view returns (Service memory) { return _services[serviceId]; }
    function getOrder(uint256 orderId) external view returns (Order memory) { return _orders[orderId]; }

    function _getOrder(uint256 orderId) internal view returns (Order storage) {
        if (orderId >= orderCount) revert OrderNotFound(orderId);
        return _orders[orderId];
    }
}
