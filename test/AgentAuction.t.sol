// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentAuction} from "../src/AgentAuction.sol";
import {IAgentAuction} from "../src/interfaces/IAgentAuction.sol";

contract AgentAuctionTest is Test {
    ERC20Mock usdc;
    AgentAuction auction;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address seller = makeAddr("seller");
    address bidder1 = makeAddr("bidder1");
    address bidder2 = makeAddr("bidder2");
    address bidder3 = makeAddr("bidder3");

    uint256 constant FEE_BPS = 200; // 2%
    uint256 constant BPS = 10_000;
    uint256 constant LIST_FEE = 0.001 ether;
    uint256 constant START_BID = 100_000_000; // $100

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        auction = new AgentAuction(IERC20(address(usdc)), treasury, owner, FEE_BPS, LIST_FEE);

        vm.deal(seller, 10 ether);
        for (uint i; i < 3; i++) {
            address b = i == 0 ? bidder1 : (i == 1 ? bidder2 : bidder3);
            usdc.mint(b, 10_000_000_000);
            vm.prank(b);
            usdc.approve(address(auction), type(uint256).max);
        }
    }

    function _createDefault() internal returns (uint256) {
        vm.prank(seller);
        return auction.createAuction{value: LIST_FEE}("Test Item", "A test auction", START_BID, uint48(1 days), 0);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(auction.treasury(), treasury);
        assertEq(auction.platformFeeBps(), FEE_BPS);
        assertEq(auction.listingFee(), LIST_FEE);
        assertEq(auction.auctionCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentAuction.ZeroAddress.selector);
        new AgentAuction(IERC20(address(0)), treasury, owner, FEE_BPS, LIST_FEE);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.FeeTooHigh.selector, 1001));
        new AgentAuction(IERC20(address(usdc)), treasury, owner, 1001, LIST_FEE);
    }

    // ─── Create ─────────────────────────────────────────────────────────

    function test_createAuction() public {
        uint256 id = _createDefault();
        assertEq(id, 0);

        IAgentAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.seller, seller);
        assertEq(a.startingBid, START_BID);
        assertEq(a.highestBid, 0);
        assertEq(a.highestBidder, address(0));
        assertEq(uint8(a.status), uint8(IAgentAuction.AuctionStatus.Active));
    }

    function test_createCollectsListingFee() public {
        _createDefault();
        assertEq(auction.accumulatedEthFees(), LIST_FEE);
    }

    function test_revert_createEmptyTitle() public {
        vm.prank(seller);
        vm.expectRevert(IAgentAuction.EmptyTitle.selector);
        auction.createAuction{value: LIST_FEE}("", "desc", START_BID, uint48(1 days), 0);
    }

    function test_revert_createZeroBid() public {
        vm.prank(seller);
        vm.expectRevert(IAgentAuction.ZeroAmount.selector);
        auction.createAuction{value: LIST_FEE}("T", "d", 0, uint48(1 days), 0);
    }

    function test_revert_createDurationTooShort() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.InvalidDuration.selector, uint48(30 minutes)));
        auction.createAuction{value: LIST_FEE}("T", "d", START_BID, uint48(30 minutes), 0);
    }

    function test_revert_createDurationTooLong() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.InvalidDuration.selector, uint48(8 days)));
        auction.createAuction{value: LIST_FEE}("T", "d", START_BID, uint48(8 days), 0);
    }

    function test_revert_createInvalidCategory() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.InvalidCategory.selector, 5));
        auction.createAuction{value: LIST_FEE}("T", "d", START_BID, uint48(1 days), 5);
    }

    function test_revert_createInsufficientFee() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.InsufficientFee.selector, LIST_FEE, 0));
        auction.createAuction("T", "d", START_BID, uint48(1 days), 0);
    }

    // ─── Bid ────────────────────────────────────────────────────────────

    function test_firstBid() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        IAgentAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.highestBid, START_BID);
        assertEq(a.highestBidder, bidder1);
    }

    function test_outbid() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        uint256 bidder1Before = usdc.balanceOf(bidder1);
        uint256 newBid = START_BID + START_BID * 500 / BPS; // +5%

        vm.prank(bidder2);
        auction.placeBid(id, newBid);

        IAgentAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.highestBidder, bidder2);
        assertEq(a.highestBid, newBid);

        // bidder1 refunded
        assertEq(usdc.balanceOf(bidder1) - bidder1Before, START_BID);
    }

    function test_multipleBids() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        uint256 bid2 = START_BID * 105 / 100;
        vm.prank(bidder2);
        auction.placeBid(id, bid2);

        uint256 bid3 = bid2 * 105 / 100;
        vm.prank(bidder3);
        auction.placeBid(id, bid3);

        assertEq(auction.getAuction(id).highestBidder, bidder3);
    }

    function test_revert_bidTooLow() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        vm.prank(bidder2);
        vm.expectRevert();
        auction.placeBid(id, START_BID); // same amount — not 5% higher
    }

    function test_revert_bidBelowStarting() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        vm.expectRevert();
        auction.placeBid(id, START_BID - 1);
    }

    function test_revert_selfBid() public {
        uint256 id = _createDefault();

        usdc.mint(seller, 1_000_000_000);
        vm.prank(seller);
        usdc.approve(address(auction), type(uint256).max);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.SelfBid.selector, id));
        auction.placeBid(id, START_BID);
    }

    function test_revert_bidAfterEnd() public {
        uint256 id = _createDefault();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.AuctionNotActive.selector, id));
        auction.placeBid(id, START_BID);
    }

    // ─── Settle ─────────────────────────────────────────────────────────

    function test_settleWithWinner() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 sellerBefore = usdc.balanceOf(seller);
        auction.settleAuction(id);

        uint256 fee = START_BID * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(seller) - sellerBefore, START_BID - fee);
        assertEq(auction.accumulatedUsdcFees(), fee);

        assertEq(uint8(auction.getAuction(id).status), uint8(IAgentAuction.AuctionStatus.Settled));
    }

    function test_settleNoBids() public {
        uint256 id = _createDefault();
        vm.warp(block.timestamp + 1 days + 1);

        auction.settleAuction(id);
        assertEq(uint8(auction.getAuction(id).status), uint8(IAgentAuction.AuctionStatus.Settled));
    }

    function test_revert_settleBeforeEnd() public {
        uint256 id = _createDefault();

        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.AuctionNotEnded.selector, id));
        auction.settleAuction(id);
    }

    function test_revert_settleAlreadySettled() public {
        uint256 id = _createDefault();
        vm.warp(block.timestamp + 1 days + 1);
        auction.settleAuction(id);

        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.AuctionNotActive.selector, id));
        auction.settleAuction(id);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    function test_cancelNoBids() public {
        uint256 id = _createDefault();

        vm.prank(seller);
        auction.cancelAuction(id);

        assertEq(uint8(auction.getAuction(id).status), uint8(IAgentAuction.AuctionStatus.Cancelled));
    }

    function test_revert_cancelWithBids() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.AuctionHasBids.selector, id));
        auction.cancelAuction(id);
    }

    function test_revert_cancelNotSeller() public {
        uint256 id = _createDefault();

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.NotSeller.selector, id));
        auction.cancelAuction(id);
    }

    // ─── Claimable Refund ───────────────────────────────────────────────

    function test_claimRefund() public {
        // we can't easily force a USDC transfer failure in tests
        // but we can test the claim path by manually setting claimable
        // Instead, test that claimRefund reverts when nothing to claim
    }

    function test_revert_claimNothing() public {
        vm.prank(bidder1);
        vm.expectRevert(IAgentAuction.NothingToClaim.selector);
        auction.claimRefund();
    }

    function test_getClaimableZero() public view {
        assertEq(auction.getClaimable(bidder1), 0);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectBothFees() public {
        uint256 id = _createDefault(); // listing fee (ETH)

        vm.prank(bidder1);
        auction.placeBid(id, START_BID);

        vm.warp(block.timestamp + 1 days + 1);
        auction.settleAuction(id); // platform fee (USDC)

        uint256 ethBefore = treasury.balance;
        uint256 usdcBefore = usdc.balanceOf(treasury);

        auction.collectFees();

        assertEq(treasury.balance - ethBefore, LIST_FEE);
        assertEq(usdc.balanceOf(treasury) - usdcBefore, START_BID * FEE_BPS / BPS);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentAuction.NoFeesToCollect.selector);
        auction.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        auction.setPlatformFeeBps(300);
        assertEq(auction.platformFeeBps(), 300);
    }

    function test_revert_setFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.FeeTooHigh.selector, 1001));
        auction.setPlatformFeeBps(1001);
    }

    function test_setListingFee() public {
        vm.prank(owner);
        auction.setListingFee(0.005 ether);
        assertEq(auction.listingFee(), 0.005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        auction.setTreasury(newT);
        assertEq(auction.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentAuction.ZeroAddress.selector);
        auction.setTreasury(address(0));
    }

    function test_revert_getAuctionNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentAuction.AuctionNotFound.selector, 999));
        auction.getAuction(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_bidIncrement(uint256 firstBid) public {
        firstBid = bound(firstBid, START_BID, 1_000_000_000);
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, firstBid);

        uint256 minNext = firstBid + firstBid * 500 / BPS;
        vm.prank(bidder2);
        auction.placeBid(id, minNext);

        assertEq(auction.getAuction(id).highestBidder, bidder2);
    }

    function testFuzz_settlePaysSeller(uint256 bid) public {
        bid = bound(bid, START_BID, 5_000_000_000);
        uint256 id = _createDefault();

        vm.prank(bidder1);
        auction.placeBid(id, bid);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 sellerBefore = usdc.balanceOf(seller);
        auction.settleAuction(id);

        uint256 fee = bid * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(seller) - sellerBefore, bid - fee);
    }
}
