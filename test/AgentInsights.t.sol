// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentInsights} from "../src/AgentInsights.sol";
import {IAgentInsights} from "../src/interfaces/IAgentInsights.sol";

contract AgentInsightsTest is Test {
    AgentInsights insights;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address protocol1 = makeAddr("protocol1");
    address protocol2 = makeAddr("protocol2");
    address external_ = makeAddr("external");

    uint256 constant QUERY_FEE = 0.001 ether;
    bytes32 constant VAULT_TVL = keccak256("VAULT_TVL");
    bytes32 constant AGENTS = keccak256("REGISTRY_AGENTS");

    function setUp() public {
        insights = new AgentInsights(treasury, owner, QUERY_FEE);

        vm.prank(owner);
        insights.authorizeProtocol(protocol1);

        vm.deal(external_, 10 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(insights.treasury(), treasury);
        assertEq(insights.owner(), owner);
        assertEq(insights.queryFee(), QUERY_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentInsights.ZeroAddress.selector);
        new AgentInsights(address(0), owner, QUERY_FEE);
    }

    function test_metricConstants() public view {
        assertEq(insights.VAULT_TVL(), keccak256("VAULT_TVL"));
        assertEq(insights.REGISTRY_AGENTS(), keccak256("REGISTRY_AGENTS"));
        assertEq(insights.ESCROW_VOLUME(), keccak256("ESCROW_VOLUME"));
    }

    // ─── Record Metric ──────────────────────────────────────────────────

    function test_recordMetric() public {
        vm.prank(protocol1);
        insights.recordMetric(VAULT_TVL, 1_000_000e6);

        (uint256 val, uint48 ts) = insights.getMetric(VAULT_TVL);
        assertEq(val, 1_000_000e6);
        assertEq(ts, uint48(block.timestamp));
    }

    function test_recordMultipleMetrics() public {
        vm.startPrank(protocol1);
        insights.recordMetric(VAULT_TVL, 500_000e6);
        insights.recordMetric(AGENTS, 42);
        vm.stopPrank();

        (uint256 tvl,) = insights.getMetric(VAULT_TVL);
        (uint256 agents,) = insights.getMetric(AGENTS);
        assertEq(tvl, 500_000e6);
        assertEq(agents, 42);
    }

    function test_recordUpdatesHistory() public {
        vm.startPrank(protocol1);
        insights.recordMetric(VAULT_TVL, 100);
        vm.warp(block.timestamp + 1 hours);
        insights.recordMetric(VAULT_TVL, 200);
        vm.warp(block.timestamp + 1 hours);
        insights.recordMetric(VAULT_TVL, 300);
        vm.stopPrank();

        (uint256[] memory vals, uint48[] memory ts) = insights.getMetricHistory(VAULT_TVL, 3);
        assertEq(vals.length, 3);
        assertEq(vals[0], 100);
        assertEq(vals[1], 200);
        assertEq(vals[2], 300);
        assertLt(ts[0], ts[1]);
    }

    function test_historyLimit() public {
        vm.startPrank(protocol1);
        insights.recordMetric(VAULT_TVL, 100);
        insights.recordMetric(VAULT_TVL, 200);
        insights.recordMetric(VAULT_TVL, 300);
        vm.stopPrank();

        (uint256[] memory vals,) = insights.getMetricHistory(VAULT_TVL, 2);
        assertEq(vals.length, 2);
        assertEq(vals[0], 200);
        assertEq(vals[1], 300);
    }

    function test_revert_recordUnauthorized() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.NotAuthorizedProtocol.selector, external_));
        insights.recordMetric(VAULT_TVL, 100);
    }

    function test_revert_recordWhenPaused() public {
        vm.prank(owner);
        insights.pause();

        vm.prank(protocol1);
        vm.expectRevert();
        insights.recordMetric(VAULT_TVL, 100);
    }

    function test_revert_getMetricNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.MetricNotFound.selector, VAULT_TVL));
        insights.getMetric(VAULT_TVL);
    }

    // ─── Snapshot ────────────────────────────────────────────────────────

    function test_updateSnapshot() public {
        IAgentInsights.EcosystemStats memory stats = IAgentInsights.EcosystemStats({
            totalTVL: 5_000_000e6,
            totalAgents: 1000,
            totalVolume24h: 250_000e6,
            totalFeesCollected: 50_000e6,
            activeEscrows: 42,
            activeInsuranceMembers: 200,
            nexusStaked: 10_000_000e18,
            snapshotTimestamp: 0 // will be overwritten
        });

        vm.prank(protocol1);
        insights.updateSnapshot(stats);

        IAgentInsights.EcosystemStats memory result = insights.getEcosystemSnapshot();
        assertEq(result.totalTVL, 5_000_000e6);
        assertEq(result.totalAgents, 1000);
        assertEq(result.snapshotTimestamp, uint48(block.timestamp));
    }

    function test_updateSnapshotByOwner() public {
        IAgentInsights.EcosystemStats memory stats = IAgentInsights.EcosystemStats({
            totalTVL: 1e6, totalAgents: 1, totalVolume24h: 0,
            totalFeesCollected: 0, activeEscrows: 0,
            activeInsuranceMembers: 0, nexusStaked: 0, snapshotTimestamp: 0
        });

        vm.prank(owner);
        insights.updateSnapshot(stats);

        assertEq(insights.getEcosystemSnapshot().totalAgents, 1);
    }

    function test_revert_updateSnapshotUnauthorized() public {
        IAgentInsights.EcosystemStats memory stats;

        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.NotAuthorizedProtocol.selector, external_));
        insights.updateSnapshot(stats);
    }

    // ─── Batch Query (paid) ─────────────────────────────────────────────

    function test_queryMetrics() public {
        vm.startPrank(protocol1);
        insights.recordMetric(VAULT_TVL, 1000);
        insights.recordMetric(AGENTS, 50);
        vm.stopPrank();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = VAULT_TVL;
        ids[1] = AGENTS;

        vm.prank(external_);
        uint256[] memory vals = insights.queryMetrics{value: QUERY_FEE}(ids);

        assertEq(vals[0], 1000);
        assertEq(vals[1], 50);
        assertEq(insights.accumulatedFees(), QUERY_FEE);
    }

    function test_queryMetricsUnrecordedReturnsZero() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = keccak256("NONEXISTENT");

        vm.prank(external_);
        uint256[] memory vals = insights.queryMetrics{value: QUERY_FEE}(ids);

        assertEq(vals[0], 0);
    }

    function test_revert_queryEmptyArray() public {
        bytes32[] memory ids = new bytes32[](0);

        vm.prank(external_);
        vm.expectRevert(IAgentInsights.EmptyQuery.selector);
        insights.queryMetrics{value: QUERY_FEE}(ids);
    }

    function test_revert_queryInsufficientFee() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = VAULT_TVL;

        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.InsufficientFee.selector, QUERY_FEE, 0));
        insights.queryMetrics(ids);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = VAULT_TVL;

        vm.prank(external_);
        insights.queryMetrics{value: QUERY_FEE}(ids);

        uint256 before_ = treasury.balance;
        insights.collectFees();
        assertEq(treasury.balance - before_, QUERY_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentInsights.NoFeesToCollect.selector);
        insights.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizeProtocol() public {
        vm.prank(owner);
        insights.authorizeProtocol(protocol2);
        assertTrue(insights.isAuthorizedProtocol(protocol2));
    }

    function test_revokeProtocol() public {
        vm.prank(owner);
        insights.revokeProtocol(protocol1);
        assertFalse(insights.isAuthorizedProtocol(protocol1));
    }

    function test_revert_authorizeZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentInsights.ZeroAddress.selector);
        insights.authorizeProtocol(address(0));
    }

    function test_revert_authorizeDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.AlreadyAuthorized.selector, protocol1));
        insights.authorizeProtocol(protocol1);
    }

    function test_revert_revokeNotAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsights.NotAuthorized.selector, protocol2));
        insights.revokeProtocol(protocol2);
    }

    function test_setQueryFee() public {
        vm.prank(owner);
        insights.setQueryFee(0.005 ether);
        assertEq(insights.queryFee(), 0.005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        insights.setTreasury(newT);
        assertEq(insights.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentInsights.ZeroAddress.selector);
        insights.setTreasury(address(0));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_recordAndQuery(uint256 value) public {
        value = bound(value, 1, type(uint128).max);

        vm.prank(protocol1);
        insights.recordMetric(VAULT_TVL, value);

        (uint256 val,) = insights.getMetric(VAULT_TVL);
        assertEq(val, value);
    }

    function testFuzz_historyAccumulates(uint8 count) public {
        count = uint8(bound(count, 1, 50));

        vm.startPrank(protocol1);
        for (uint i; i < count; i++) {
            insights.recordMetric(VAULT_TVL, i + 1);
        }
        vm.stopPrank();

        (uint256[] memory vals,) = insights.getMetricHistory(VAULT_TVL, count);
        assertEq(vals.length, count);
        assertEq(vals[count - 1], count);
    }

    function testFuzz_queryFeeAccumulates(uint8 queries) public {
        queries = uint8(bound(queries, 1, 20));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = VAULT_TVL;

        for (uint i; i < queries; i++) {
            vm.prank(external_);
            insights.queryMetrics{value: QUERY_FEE}(ids);
        }
        assertEq(insights.accumulatedFees(), uint256(queries) * QUERY_FEE);
    }
}
