// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentMarket} from "../src/AgentMarket.sol";
import {IAgentMarket} from "../src/interfaces/IAgentMarket.sol";

contract AgentMarketTest is Test {
    ERC20Mock usdc;
    AgentMarket market;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;
    uint256 constant MIN_PRICE = 1_000_000; // $1 USDC
    uint256 constant SERVICE_PRICE = 50_000_000; // $50 USDC
    uint256 constant DISPUTE_WINDOW = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        market = new AgentMarket(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        // fund buyer with USDC and approve market
        usdc.mint(buyer, 1_000_000_000); // $1000
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);

        // fund stranger too
        usdc.mint(stranger, 1_000_000_000);
        vm.prank(stranger);
        usdc.approve(address(market), type(uint256).max);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(market.paymentToken()), address(usdc));
        assertEq(market.treasury(), treasury);
        assertEq(market.owner(), owner);
        assertEq(market.platformFeeBps(), FEE_BPS);
        assertEq(market.serviceCount(), 0);
        assertEq(market.orderCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentMarket.ZeroAddress.selector);
        new AgentMarket(IERC20(address(0)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentMarket.ZeroAddress.selector);
        new AgentMarket(IERC20(address(usdc)), address(0), owner, FEE_BPS);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.FeeTooHigh.selector, 1001));
        new AgentMarket(IERC20(address(usdc)), treasury, owner, 1001);
    }

    // ─── List Service ───────────────────────────────────────────────────

    function test_listService() public {
        vm.prank(seller);
        market.listService("Data Analysis", "https://api.agent.com/data", SERVICE_PRICE, 0);

        assertEq(market.serviceCount(), 1);

        IAgentMarket.Service memory s = market.getService(0);
        assertEq(s.seller, seller);
        assertEq(s.name, "Data Analysis");
        assertEq(s.endpoint, "https://api.agent.com/data");
        assertEq(s.priceUsdc, SERVICE_PRICE);
        assertEq(s.category, 0);
        assertTrue(s.active);
        assertEq(s.totalSales, 0);
        assertEq(s.totalRating, 0);
        assertEq(s.ratingCount, 0);
    }

    function test_revert_listServiceEmptyName() public {
        vm.prank(seller);
        vm.expectRevert(IAgentMarket.EmptyName.selector);
        market.listService("", "https://api.test", SERVICE_PRICE, 0);
    }

    function test_revert_listServiceEmptyEndpoint() public {
        vm.prank(seller);
        vm.expectRevert(IAgentMarket.EmptyEndpoint.selector);
        market.listService("Agent", "", SERVICE_PRICE, 0);
    }

    function test_revert_listServicePriceTooLow() public {
        vm.prank(seller);
        vm.expectRevert(IAgentMarket.InvalidPrice.selector);
        market.listService("Cheap", "https://api.test", MIN_PRICE - 1, 0);
    }

    function test_revert_listServiceInvalidCategory() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.InvalidCategory.selector, uint8(5)));
        market.listService("Bad Cat", "https://api.test", SERVICE_PRICE, 5);
    }

    function test_revert_listServiceWhenPaused() public {
        vm.prank(owner);
        market.pause();

        vm.prank(seller);
        vm.expectRevert();
        market.listService("Paused", "https://api.test", SERVICE_PRICE, 0);
    }

    // ─── Delist Service ─────────────────────────────────────────────────

    function test_delistService() public {
        vm.prank(seller);
        market.listService("To Delist", "https://api.test", SERVICE_PRICE, 0);

        vm.prank(seller);
        market.delistService(0);

        IAgentMarket.Service memory s = market.getService(0);
        assertFalse(s.active);
    }

    function test_revert_delistServiceNotSeller() public {
        vm.prank(seller);
        market.listService("Not yours", "https://api.test", SERVICE_PRICE, 0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.NotSeller.selector, 0));
        market.delistService(0);
    }

    // ─── Purchase Service ───────────────────────────────────────────────

    function test_purchaseService() public {
        vm.prank(seller);
        market.listService("Buy Me", "https://api.test", SERVICE_PRICE, 0);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        market.purchaseService(0, keccak256("request-data"));

        assertEq(market.orderCount(), 1);
        assertEq(usdc.balanceOf(buyer), buyerBefore - SERVICE_PRICE);
        assertEq(usdc.balanceOf(address(market)), SERVICE_PRICE);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertEq(o.serviceId, 0);
        assertEq(o.buyer, buyer);
        assertEq(o.seller, seller);
        assertEq(o.amount, SERVICE_PRICE);
        assertTrue(o.status == IAgentMarket.OrderStatus.Active);
    }

    function test_revert_purchaseDelistedService() public {
        vm.prank(seller);
        market.listService("Delisted", "https://api.test", SERVICE_PRICE, 0);

        vm.prank(seller);
        market.delistService(0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.ServiceNotActive.selector, 0));
        market.purchaseService(0, keccak256("req"));
    }

    // ─── Confirm Delivery ───────────────────────────────────────────────

    function test_confirmDelivery_paysFeeAndSeller() public {
        _createAndPurchase();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        market.confirmDelivery(0);

        uint256 expectedFee = SERVICE_PRICE * FEE_BPS / BPS; // 1% = 500_000
        uint256 expectedPayout = SERVICE_PRICE - expectedFee;

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
        assertEq(usdc.balanceOf(seller) - sellerBefore, expectedPayout);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Delivered);
    }

    function test_confirmDelivery_incrementsSales() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        IAgentMarket.Service memory s = market.getService(0);
        assertEq(s.totalSales, 1);
    }

    function test_revert_confirmDeliveryNotBuyer() public {
        _createAndPurchase();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.NotBuyer.selector, 0));
        market.confirmDelivery(0);
    }

    function test_revert_confirmDeliveryTwice() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.WrongOrderStatus.selector, 0));
        market.confirmDelivery(0);
    }

    // ─── Dispute Order ──────────────────────────────────────────────────

    function test_disputeOrderByBuyer() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.disputeOrder(0);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Disputed);
    }

    function test_disputeOrderBySeller() public {
        _createAndPurchase();

        vm.prank(seller);
        market.disputeOrder(0);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Disputed);
    }

    function test_revert_disputeByStranger() public {
        _createAndPurchase();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.NotParty.selector, 0));
        market.disputeOrder(0);
    }

    function test_revert_disputeAfterWindow() public {
        _createAndPurchase();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.DisputeWindowClosed.selector, 0));
        market.disputeOrder(0);
    }

    function test_revert_disputeDeliveredOrder() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.WrongOrderStatus.selector, 0));
        market.disputeOrder(0);
    }

    // ─── Resolve Dispute ────────────────────────────────────────────────

    function test_resolveDisputeToSeller() public {
        _createAndDispute();

        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(owner);
        market.resolveDispute(0, true);

        uint256 expectedFee = SERVICE_PRICE * FEE_BPS / BPS;
        uint256 expectedPayout = SERVICE_PRICE - expectedFee;

        assertEq(usdc.balanceOf(seller) - sellerBefore, expectedPayout);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Resolved);
    }

    function test_resolveDisputeToBuyer() public {
        _createAndDispute();

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(owner);
        market.resolveDispute(0, false);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, SERVICE_PRICE);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Resolved);
    }

    function test_revert_resolveDisputeNotOwner() public {
        _createAndDispute();

        vm.prank(buyer);
        vm.expectRevert();
        market.resolveDispute(0, true);
    }

    function test_revert_resolveNotDisputed() public {
        _createAndPurchase();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.WrongOrderStatus.selector, 0));
        market.resolveDispute(0, true);
    }

    // ─── Refund Order ───────────────────────────────────────────────────

    function test_refundAfterDisputeWindow() public {
        _createAndPurchase();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        market.refundOrder(0);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, SERVICE_PRICE);

        IAgentMarket.Order memory o = market.getOrder(0);
        assertTrue(o.status == IAgentMarket.OrderStatus.Refunded);
    }

    function test_revert_refundBeforeDisputeWindowCloses() public {
        _createAndPurchase();

        // still within dispute window
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.DisputeWindowClosed.selector, 0));
        market.refundOrder(0);
    }

    function test_revert_refundDeliveredOrder() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.WrongOrderStatus.selector, 0));
        market.refundOrder(0);
    }

    // ─── Rate Service ───────────────────────────────────────────────────

    function test_rateService() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(buyer);
        market.rateService(0, 5);

        IAgentMarket.Service memory s = market.getService(0);
        assertEq(s.totalRating, 5);
        assertEq(s.ratingCount, 1);
    }

    function test_revert_rateNotBuyer() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.NotBuyer.selector, 0));
        market.rateService(0, 4);
    }

    function test_revert_rateNotDelivered() public {
        _createAndPurchase();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.WrongOrderStatus.selector, 0));
        market.rateService(0, 3);
    }

    function test_revert_rateInvalidRating_zero() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.InvalidRating.selector, uint8(0)));
        market.rateService(0, 0);
    }

    function test_revert_rateInvalidRating_six() public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.InvalidRating.selector, uint8(6)));
        market.rateService(0, 6);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        market.setPlatformFeeBps(500); // 5%

        assertEq(market.platformFeeBps(), 500);
    }

    function test_revert_setPlatformFeeBpsTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentMarket.FeeTooHigh.selector, 1001));
        market.setPlatformFeeBps(1001);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        market.setTreasury(newTreasury);

        assertEq(market.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentMarket.ZeroAddress.selector);
        market.setTreasury(address(0));
    }

    // ─── Order Not Found ────────────────────────────────────────────────

    function test_getOrderOutOfRange_returnsDefault() public view {
        // getOrder uses direct mapping access (no bounds check), returns default struct
        IAgentMarket.Order memory o = market.getOrder(999);
        assertEq(o.buyer, address(0));
        assertEq(o.amount, 0);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_purchaseAmounts(uint256 price) public {
        price = bound(price, MIN_PRICE, 500_000_000); // $1 to $500

        vm.prank(seller);
        market.listService("Fuzz Service", "https://fuzz.test", price, 0);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        market.purchaseService(0, keccak256("fuzz-req"));

        assertEq(usdc.balanceOf(buyer), buyerBefore - price);
        assertEq(usdc.balanceOf(address(market)), price);
    }

    function testFuzz_feeCalculation(uint256 price, uint256 feeBps) public {
        price = bound(price, MIN_PRICE, 500_000_000);
        feeBps = bound(feeBps, 0, 1000); // 0-10%

        AgentMarket fuzzMarket = new AgentMarket(IERC20(address(usdc)), treasury, owner, feeBps);

        vm.prank(seller);
        fuzzMarket.listService("Fuzz Fee", "https://fuzz.test", price, 0);

        usdc.mint(buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fuzzMarket), price);

        vm.prank(buyer);
        fuzzMarket.purchaseService(0, keccak256("fuzz"));

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        fuzzMarket.confirmDelivery(0);

        uint256 expectedFee = (price * feeBps) / BPS;
        uint256 expectedPayout = price - expectedFee;

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
        assertEq(usdc.balanceOf(seller) - sellerBefore, expectedPayout);
    }

    function testFuzz_ratings(uint8 rating) public {
        _createAndPurchase();

        vm.prank(buyer);
        market.confirmDelivery(0);

        if (rating >= 1 && rating <= 5) {
            vm.prank(buyer);
            market.rateService(0, rating);

            IAgentMarket.Service memory s = market.getService(0);
            assertEq(s.totalRating, rating);
            assertEq(s.ratingCount, 1);
        } else {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(IAgentMarket.InvalidRating.selector, rating));
            market.rateService(0, rating);
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _createAndPurchase() internal {
        vm.prank(seller);
        market.listService("Test Service", "https://api.test", SERVICE_PRICE, 0);

        vm.prank(buyer);
        market.purchaseService(0, keccak256("request"));
    }

    function _createAndDispute() internal {
        _createAndPurchase();

        vm.prank(buyer);
        market.disputeOrder(0);
    }
}
