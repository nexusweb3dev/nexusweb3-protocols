// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentOracle} from "../src/AgentOracle.sol";
import {IAgentOracle} from "../src/interfaces/IAgentOracle.sol";

contract AgentOracleTest is Test {
    ERC20Mock usdc;
    AgentOracle oracle;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address publisher1 = makeAddr("publisher1");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    uint256 constant QUERY_FEE = 0.0005 ether;
    uint256 constant SUB_PRICE = 1_000_000; // $1 USDC
    bytes32 constant ETH_USD = keccak256("ETH/USD");
    bytes32 constant BTC_USD = keccak256("BTC/USD");
    bytes32 constant GAS_PRICE = keccak256("GAS_PRICE");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        oracle = new AgentOracle(IERC20(address(usdc)), treasury, owner, QUERY_FEE, SUB_PRICE);

        vm.prank(owner);
        oracle.authorizePublisher(publisher1);

        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        usdc.mint(agent1, 100_000_000);
        usdc.mint(agent2, 100_000_000);

        vm.prank(agent1);
        usdc.approve(address(oracle), type(uint256).max);
        vm.prank(agent2);
        usdc.approve(address(oracle), type(uint256).max);
    }

    function _pushEthPrice(uint256 price) internal {
        vm.prank(publisher1);
        oracle.updateFeed(ETH_USD, price, uint48(block.timestamp));
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(oracle.treasury(), treasury);
        assertEq(oracle.owner(), owner);
        assertEq(oracle.queryFee(), QUERY_FEE);
        assertEq(oracle.subscriptionPrice(), SUB_PRICE);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentOracle.ZeroAddress.selector);
        new AgentOracle(IERC20(address(0)), treasury, owner, QUERY_FEE, SUB_PRICE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentOracle.ZeroAddress.selector);
        new AgentOracle(IERC20(address(usdc)), address(0), owner, QUERY_FEE, SUB_PRICE);
    }

    // ─── Update Feed ────────────────────────────────────────────────────

    function test_updateFeed() public {
        _pushEthPrice(3500_00000000); // $3500 with 8 decimals

        (uint256 val, uint48 ts, bool stale) = oracle.getLatestValueFree(ETH_USD);
        assertEq(val, 3500_00000000);
        assertEq(ts, uint48(block.timestamp));
        assertFalse(stale);
    }

    function test_updateMultipleFeeds() public {
        _pushEthPrice(3500_00000000);

        vm.prank(publisher1);
        oracle.updateFeed(BTC_USD, 95000_00000000, uint48(block.timestamp));

        (uint256 ethVal,,) = oracle.getLatestValueFree(ETH_USD);
        (uint256 btcVal,,) = oracle.getLatestValueFree(BTC_USD);
        assertEq(ethVal, 3500_00000000);
        assertEq(btcVal, 95000_00000000);
    }

    function test_revert_updateNotPublisher() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.NotPublisher.selector, agent1));
        oracle.updateFeed(ETH_USD, 3500_00000000, uint48(block.timestamp));
    }

    function test_revert_updateZeroValue() public {
        vm.prank(publisher1);
        vm.expectRevert(IAgentOracle.ZeroValue.selector);
        oracle.updateFeed(ETH_USD, 0, uint48(block.timestamp));
    }

    function test_revert_updateFutureTimestamp() public {
        vm.prank(publisher1);
        vm.expectRevert();
        oracle.updateFeed(ETH_USD, 3500_00000000, uint48(block.timestamp + 1 hours));
    }

    function test_revert_updateWhenPaused() public {
        vm.prank(owner);
        oracle.pause();

        vm.prank(publisher1);
        vm.expectRevert();
        oracle.updateFeed(ETH_USD, 3500_00000000, uint48(block.timestamp));
    }

    // ─── Staleness ──────────────────────────────────────────────────────

    function test_feedBecomesStale() public {
        _pushEthPrice(3500_00000000);

        (, , bool staleBefore) = oracle.getLatestValueFree(ETH_USD);
        assertFalse(staleBefore);

        vm.warp(block.timestamp + 1 hours + 1);

        (, , bool staleAfter) = oracle.getLatestValueFree(ETH_USD);
        assertTrue(staleAfter);
    }

    function test_feedRefreshedNotStale() public {
        _pushEthPrice(3500_00000000);
        vm.warp(block.timestamp + 1 hours + 1);

        // refresh
        _pushEthPrice(3600_00000000);

        (, , bool stale) = oracle.getLatestValueFree(ETH_USD);
        assertFalse(stale);
    }

    // ─── Paid Query ─────────────────────────────────────────────────────

    function test_paidQuery() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        (uint256 val,,) = oracle.getLatestValue{value: QUERY_FEE}(ETH_USD);
        assertEq(val, 3500_00000000);
        assertEq(oracle.accumulatedEthFees(), QUERY_FEE);
    }

    function test_revert_paidQueryInsufficientFee() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.InsufficientFee.selector, QUERY_FEE, 0));
        oracle.getLatestValue(ETH_USD);
    }

    function test_revert_queryFeedNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.FeedNotFound.selector, ETH_USD));
        oracle.getLatestValueFree(ETH_USD);
    }

    // ─── Subscription ───────────────────────────────────────────────────

    function test_subscribe() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 3);

        assertTrue(oracle.isSubscribed(agent1, ETH_USD));
        assertEq(oracle.accumulatedUsdcFees(), SUB_PRICE * 3);
    }

    function test_subscriberQueriesFree() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 1);

        // subscriber queries without paying ETH
        vm.prank(agent1);
        (uint256 val,,) = oracle.getLatestValue(ETH_USD);
        assertEq(val, 3500_00000000);
        assertEq(oracle.accumulatedEthFees(), 0); // no ETH fee charged
    }

    function test_subscriptionExpires() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 1);

        assertTrue(oracle.isSubscribed(agent1, ETH_USD));

        vm.warp(block.timestamp + 31 days);
        assertFalse(oracle.isSubscribed(agent1, ETH_USD));
    }

    function test_subscriptionExtends() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 1);

        uint48 firstEnd = oracle.getSubscriptionExpiry(agent1, ETH_USD);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 2);

        uint48 secondEnd = oracle.getSubscriptionExpiry(agent1, ETH_USD);
        assertEq(secondEnd, firstEnd + uint48(2 * 30 days));
    }

    function test_revert_subscribeZeroMonths() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        vm.expectRevert(IAgentOracle.InvalidMonths.selector);
        oracle.subscribe(ETH_USD, 0);
    }

    function test_revert_subscribeTooManyMonths() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        vm.expectRevert(IAgentOracle.InvalidMonths.selector);
        oracle.subscribe(ETH_USD, 13);
    }

    function test_revert_subscribeFeedNotFound() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.FeedNotFound.selector, GAS_PRICE));
        oracle.subscribe(GAS_PRICE, 1);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectEthFees() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.getLatestValue{value: QUERY_FEE}(ETH_USD);

        uint256 treasuryBefore = treasury.balance;
        oracle.collectFees();
        assertEq(treasury.balance - treasuryBefore, QUERY_FEE);
    }

    function test_collectUsdcFees() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, 2);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        oracle.collectFees();
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, SUB_PRICE * 2);
    }

    function test_collectBothFees() public {
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.getLatestValue{value: QUERY_FEE}(ETH_USD);
        vm.prank(agent2);
        oracle.subscribe(ETH_USD, 1);

        uint256 ethBefore = treasury.balance;
        uint256 usdcBefore = usdc.balanceOf(treasury);

        oracle.collectFees();

        assertEq(treasury.balance - ethBefore, QUERY_FEE);
        assertEq(usdc.balanceOf(treasury) - usdcBefore, SUB_PRICE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentOracle.NoFeesToCollect.selector);
        oracle.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizePublisher() public {
        address pub2 = makeAddr("pub2");
        vm.prank(owner);
        oracle.authorizePublisher(pub2);
        assertTrue(oracle.isPublisher(pub2));
    }

    function test_revokePublisher() public {
        vm.prank(owner);
        oracle.revokePublisher(publisher1);
        assertFalse(oracle.isPublisher(publisher1));
    }

    function test_revert_authorizeZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentOracle.ZeroAddress.selector);
        oracle.authorizePublisher(address(0));
    }

    function test_revert_authorizeDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.AlreadyPublisher.selector, publisher1));
        oracle.authorizePublisher(publisher1);
    }

    function test_revert_revokeNotPublisher() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentOracle.NotAuthorizedPublisher.selector, agent1));
        oracle.revokePublisher(agent1);
    }

    function test_setQueryFee() public {
        vm.prank(owner);
        oracle.setQueryFee(0.001 ether);
        assertEq(oracle.queryFee(), 0.001 ether);
    }

    function test_setSubscriptionPrice() public {
        vm.prank(owner);
        oracle.setSubscriptionPrice(2_000_000);
        assertEq(oracle.subscriptionPrice(), 2_000_000);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        oracle.setTreasury(newT);
        assertEq(oracle.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentOracle.ZeroAddress.selector);
        oracle.setTreasury(address(0));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_updateAndQuery(uint256 price) public {
        price = bound(price, 1, type(uint128).max);

        vm.prank(publisher1);
        oracle.updateFeed(ETH_USD, price, uint48(block.timestamp));

        (uint256 val,,) = oracle.getLatestValueFree(ETH_USD);
        assertEq(val, price);
    }

    function testFuzz_subscriptionDuration(uint256 months) public {
        months = bound(months, 1, 12);
        _pushEthPrice(3500_00000000);

        vm.prank(agent1);
        oracle.subscribe(ETH_USD, months);

        uint48 expiry = oracle.getSubscriptionExpiry(agent1, ETH_USD);
        assertEq(expiry, uint48(block.timestamp) + uint48(months * 30 days));
    }

    function testFuzz_queryFeeAccumulates(uint8 queries) public {
        queries = uint8(bound(queries, 1, 20));
        _pushEthPrice(3500_00000000);

        for (uint i; i < queries; i++) {
            vm.prank(agent1);
            oracle.getLatestValue{value: QUERY_FEE}(ETH_USD);
        }

        assertEq(oracle.accumulatedEthFees(), uint256(queries) * QUERY_FEE);
    }
}
