// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentAuction} from "./interfaces/IAgentAuction.sol";

/// @notice On-chain auction house for AI agents. Bid in USDC, highest wins, losers refunded instantly.
contract AgentAuction is Ownable, ReentrancyGuard, Pausable, IAgentAuction {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MIN_BID_INCREMENT_BPS = 500; // 5% minimum increase
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1000; // 10% cap
    uint48 public constant MIN_DURATION = 1 hours;
    uint48 public constant MAX_DURATION = 7 days;
    uint8 public constant MAX_CATEGORY = 4;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    uint256 public listingFee;
    address public treasury;
    uint256 public auctionCount;
    uint256 public accumulatedEthFees;
    uint256 public accumulatedUsdcFees;

    mapping(uint256 => Auction) private _auctions;
    mapping(address => uint256) private _claimable; // failed refunds

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_,
        uint256 listingFee_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        listingFee = listingFee_;
    }

    // ─── Create ─────────────────────────────────────────────────────────

    /// @notice List an item for auction.
    function createAuction(
        string calldata title,
        string calldata description,
        uint256 startingBid,
        uint48 duration,
        uint8 category
    ) external payable nonReentrant whenNotPaused returns (uint256 auctionId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (startingBid == 0) revert ZeroAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration(duration);
        if (category > MAX_CATEGORY) revert InvalidCategory(category);
        if (msg.value < listingFee) revert InsufficientFee(listingFee, msg.value);

        auctionId = auctionCount++;
        _auctions[auctionId] = Auction({
            seller: msg.sender,
            title: title,
            description: description,
            startingBid: startingBid,
            highestBid: 0,
            highestBidder: address(0),
            endTime: uint48(block.timestamp) + duration,
            category: category,
            status: AuctionStatus.Active
        });
        accumulatedEthFees += msg.value;

        emit AuctionCreated(auctionId, msg.sender, title, startingBid, uint48(block.timestamp) + duration);
    }

    // ─── Bid ────────────────────────────────────────────────────────────

    /// @notice Place a bid. Must exceed current highest by 5%. Previous bidder refunded.
    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant whenNotPaused {
        Auction storage a = _getAuction(auctionId);
        if (a.status != AuctionStatus.Active) revert AuctionNotActive(auctionId);
        if (uint48(block.timestamp) >= a.endTime) revert AuctionNotActive(auctionId);
        if (msg.sender == a.seller) revert SelfBid(auctionId);

        uint256 minBid;
        if (a.highestBid == 0) {
            minBid = a.startingBid;
        } else {
            minBid = a.highestBid + a.highestBid * MIN_BID_INCREMENT_BPS / BPS;
        }
        if (bidAmount < minBid) revert BidTooLow(auctionId, minBid, bidAmount);

        // save previous bidder for refund
        address prevBidder = a.highestBidder;
        uint256 prevBid = a.highestBid;

        // state updates first (CEI)
        a.highestBid = bidAmount;
        a.highestBidder = msg.sender;

        // pull new bid from caller
        paymentToken.safeTransferFrom(msg.sender, address(this), bidAmount);

        // refund previous bidder — if transfer fails, store in claimable
        if (prevBidder != address(0) && prevBid > 0) {
            try this.safeRefund(prevBidder, prevBid) {} catch {
                _claimable[prevBidder] += prevBid;
            }
        }

        emit BidPlaced(auctionId, msg.sender, bidAmount);
    }

    /// @notice External helper for try/catch refund pattern.
    function safeRefund(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal only");
        paymentToken.safeTransfer(to, amount);
    }

    // ─── Settle ─────────────────────────────────────────────────────────

    /// @notice Settle auction after end time. Pays seller minus fee.
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = _getAuction(auctionId);
        if (a.status != AuctionStatus.Active) revert AuctionNotActive(auctionId);
        if (uint48(block.timestamp) < a.endTime) revert AuctionNotEnded(auctionId);

        a.status = AuctionStatus.Settled;

        if (a.highestBidder == address(0)) {
            // no bids — nothing to settle
            emit AuctionSettled(auctionId, address(0), 0, 0);
            return;
        }

        uint256 fee = a.highestBid.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 payout = a.highestBid - fee;

        if (fee > 0) {
            accumulatedUsdcFees += fee;
        }

        // seller payout — if transfer fails, store in claimable (never block settlement)
        try this.safeRefund(a.seller, payout) {} catch {
            _claimable[a.seller] += payout;
        }

        emit AuctionSettled(auctionId, a.highestBidder, payout, fee);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    /// @notice Cancel auction if no bids placed.
    function cancelAuction(uint256 auctionId) external {
        Auction storage a = _getAuction(auctionId);
        if (a.seller != msg.sender) revert NotSeller(auctionId);
        if (a.status != AuctionStatus.Active) revert AuctionNotActive(auctionId);
        if (a.highestBidder != address(0)) revert AuctionHasBids(auctionId);

        a.status = AuctionStatus.Cancelled;
        emit AuctionCancelled(auctionId);
    }

    // ─── Claim Failed Refund ────────────────────────────────────────────

    /// @notice Claim USDC from a failed bid refund.
    function claimRefund() external nonReentrant {
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();

        _claimable[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);

        emit RefundClaimed(msg.sender, amount);
    }

    function getClaimable(address bidder) external view returns (uint256) {
        return _claimable[bidder];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

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

    function setPlatformFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
    }

    function setListingFee(uint256 newFee) external onlyOwner {
        uint256 old = listingFee;
        listingFee = newFee;
        emit ListingFeeUpdated(old, newFee);
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

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        if (auctionId >= auctionCount) revert AuctionNotFound(auctionId);
        return _auctions[auctionId];
    }

    function _getAuction(uint256 auctionId) internal view returns (Auction storage) {
        if (auctionId >= auctionCount) revert AuctionNotFound(auctionId);
        return _auctions[auctionId];
    }
}
