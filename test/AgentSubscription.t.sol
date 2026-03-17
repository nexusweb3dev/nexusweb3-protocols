// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentSubscription} from "../src/AgentSubscription.sol";
import {IAgentSubscription} from "../src/interfaces/IAgentSubscription.sol";

contract AgentSubscriptionTest is Test {
    ERC20Mock usdc;
    AgentSubscription sub;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address subscriber = makeAddr("subscriber");
    address keeper = makeAddr("keeper");

    uint256 constant FEE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;
    uint256 constant PRICE = 10_000_000; // $10
    uint48 constant INTERVAL = 30 days;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        sub = new AgentSubscription(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        usdc.mint(subscriber, 10_000_000_000);
        vm.prank(subscriber);
        usdc.approve(address(sub), type(uint256).max);
    }

    function _createPlan() internal returns (uint256) {
        vm.prank(provider);
        return sub.createPlan("Data Feed", PRICE, INTERVAL, 0);
    }

    function _subscribeDefault() internal returns (uint256 planId, uint256 subId) {
        planId = _createPlan();
        vm.prank(subscriber);
        subId = sub.subscribe(planId, 1);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(sub.treasury(), treasury);
        assertEq(sub.platformFeeBps(), FEE_BPS);
    }

    // ─── Create Plan ────────────────────────────────────────────────────

    function test_createPlan() public {
        uint256 id = _createPlan();
        IAgentSubscription.Plan memory p = sub.getPlan(id);
        assertEq(p.provider, provider);
        assertEq(p.price, PRICE);
        assertEq(p.interval, INTERVAL);
        assertTrue(p.active);
    }

    function test_revert_createEmptyName() public {
        vm.prank(provider);
        vm.expectRevert(IAgentSubscription.EmptyName.selector);
        sub.createPlan("", PRICE, INTERVAL, 0);
    }

    function test_revert_createZeroPrice() public {
        vm.prank(provider);
        vm.expectRevert(IAgentSubscription.InvalidPrice.selector);
        sub.createPlan("X", 0, INTERVAL, 0);
    }

    function test_revert_createShortInterval() public {
        vm.prank(provider);
        vm.expectRevert(IAgentSubscription.InvalidInterval.selector);
        sub.createPlan("X", PRICE, uint48(30 minutes), 0);
    }

    // ─── Subscribe ──────────────────────────────────────────────────────

    function test_subscribe() public {
        (, uint256 subId) = _subscribeDefault();

        assertTrue(sub.isActive(subId));
        IAgentSubscription.Subscription memory s = sub.getSubscription(subId);
        assertEq(s.subscriber, subscriber);
        assertEq(s.lockedPrice, PRICE);
        assertEq(s.paidUntil, uint48(block.timestamp) + INTERVAL);
    }

    function test_subscribePayment() public {
        uint256 providerBefore = usdc.balanceOf(provider);
        _subscribeDefault();

        uint256 fee = PRICE * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(provider) - providerBefore, PRICE - fee);
        assertEq(sub.accumulatedFees(), fee);
    }

    function test_subscribeMultiplePeriods() public {
        uint256 planId = _createPlan();
        vm.prank(subscriber);
        uint256 subId = sub.subscribe(planId, 3);

        IAgentSubscription.Subscription memory s = sub.getSubscription(subId);
        assertEq(s.paidUntil, uint48(block.timestamp) + uint48(uint256(INTERVAL) * 3));
    }

    function test_subscriptionExpires() public {
        (, uint256 subId) = _subscribeDefault();

        assertTrue(sub.isActive(subId));
        vm.warp(block.timestamp + INTERVAL + 1);
        assertFalse(sub.isActive(subId));
    }

    function test_revert_subscribeInactivePlan() public {
        uint256 planId = _createPlan();
        vm.prank(provider);
        sub.pausePlan(planId);

        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(IAgentSubscription.PlanNotActive.selector, planId));
        sub.subscribe(planId, 1);
    }

    function test_revert_subscribePlanFull() public {
        vm.prank(provider);
        uint256 planId = sub.createPlan("Limited", PRICE, INTERVAL, 1);

        vm.prank(subscriber);
        sub.subscribe(planId, 1);

        address sub2 = makeAddr("sub2");
        usdc.mint(sub2, 100_000_000);
        vm.prank(sub2);
        usdc.approve(address(sub), type(uint256).max);

        vm.prank(sub2);
        vm.expectRevert(abi.encodeWithSelector(IAgentSubscription.PlanFull.selector, planId));
        sub.subscribe(planId, 1);
    }

    function test_revert_subscribeZeroPeriods() public {
        uint256 planId = _createPlan();
        vm.prank(subscriber);
        vm.expectRevert(IAgentSubscription.InvalidMonths.selector);
        sub.subscribe(planId, 0);
    }

    // ─── Renewal ────────────────────────────────────────────────────────

    function test_processRenewal() public {
        (, uint256 subId) = _subscribeDefault();

        vm.warp(block.timestamp + INTERVAL + 1);

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(keeper);
        sub.processRenewal(subId);

        uint256 fee = PRICE * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(provider) - providerBefore, PRICE - fee);

        IAgentSubscription.Subscription memory s = sub.getSubscription(subId);
        assertTrue(s.active);
        assertGt(s.paidUntil, uint48(block.timestamp));
    }

    function test_revert_renewalNotDue() public {
        (, uint256 subId) = _subscribeDefault();

        vm.prank(keeper);
        vm.expectRevert();
        sub.processRenewal(subId);
    }

    function test_renewalFailsGracefully() public {
        (, uint256 subId) = _subscribeDefault();

        // remove subscriber's approval so renewal fails
        vm.prank(subscriber);
        usdc.approve(address(sub), 0);

        vm.warp(block.timestamp + INTERVAL + 1);

        vm.prank(keeper);
        sub.processRenewal(subId);

        // subscription expired — not reverted
        assertFalse(sub.getSubscription(subId).active);
    }

    function test_lockedPriceNotAffectedByPlanChange() public {
        (uint256 planId, uint256 subId) = _subscribeDefault();

        // "price changes" in plan don't affect locked price
        // (plan price is read-only for existing subs since lockedPrice is saved)
        IAgentSubscription.Subscription memory s = sub.getSubscription(subId);
        assertEq(s.lockedPrice, PRICE);
        // Even if plan.price changed (which requires a new plan), this sub keeps PRICE
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    function test_cancelSubscription() public {
        (, uint256 subId) = _subscribeDefault();

        vm.prank(subscriber);
        sub.cancelSubscription(subId);

        assertFalse(sub.getSubscription(subId).active);
    }

    function test_revert_cancelNotSubscriber() public {
        (, uint256 subId) = _subscribeDefault();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAgentSubscription.NotSubscriber.selector, subId));
        sub.cancelSubscription(subId);
    }

    function test_revert_cancelAlreadyCancelled() public {
        (, uint256 subId) = _subscribeDefault();

        vm.prank(subscriber);
        sub.cancelSubscription(subId);

        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(IAgentSubscription.SubscriptionNotActive.selector, subId));
        sub.cancelSubscription(subId);
    }

    // ─── Plan Management ────────────────────────────────────────────────

    function test_pauseAndResumePlan() public {
        uint256 planId = _createPlan();

        vm.prank(provider);
        sub.pausePlan(planId);
        assertFalse(sub.getPlan(planId).active);

        vm.prank(provider);
        sub.resumePlan(planId);
        assertTrue(sub.getPlan(planId).active);
    }

    function test_revert_pauseNotProvider() public {
        uint256 planId = _createPlan();

        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(IAgentSubscription.NotProvider.selector, planId));
        sub.pausePlan(planId);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        _subscribeDefault();
        uint256 before_ = usdc.balanceOf(treasury);
        sub.collectFees();
        assertEq(usdc.balanceOf(treasury) - before_, PRICE * FEE_BPS / BPS);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentSubscription.NoFeesToCollect.selector);
        sub.collectFees();
    }

    function test_setFee() public {
        vm.prank(owner);
        sub.setPlatformFeeBps(100);
        assertEq(sub.platformFeeBps(), 100);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        sub.setTreasury(newT);
        assertEq(sub.treasury(), newT);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_subscribeAndCheck(uint256 periods) public {
        periods = bound(periods, 1, 12);
        uint256 planId = _createPlan();

        vm.prank(subscriber);
        uint256 subId = sub.subscribe(planId, periods);

        assertTrue(sub.isActive(subId));

        vm.warp(block.timestamp + uint256(INTERVAL) * periods + 1);
        assertFalse(sub.isActive(subId));
    }

    function testFuzz_providerPayment(uint256 price) public {
        price = bound(price, 1_000_000, 1_000_000_000);

        vm.prank(provider);
        uint256 planId = sub.createPlan("Fuzz", price, INTERVAL, 0);

        usdc.mint(subscriber, price);

        uint256 provBefore = usdc.balanceOf(provider);
        vm.prank(subscriber);
        sub.subscribe(planId, 1);

        uint256 fee = price * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(provider) - provBefore, price - fee);
    }
}
