// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentReputation} from "../src/AgentReputation.sol";
import {IAgentReputation} from "../src/interfaces/IAgentReputation.sol";

contract AgentReputationTest is Test {
    AgentReputation rep;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address protocol1 = makeAddr("protocol1");
    address protocol2 = makeAddr("protocol2");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address external_ = makeAddr("external");

    uint256 constant QUERY_FEE = 0.001 ether;

    function setUp() public {
        rep = new AgentReputation(treasury, owner, QUERY_FEE);
        vm.prank(owner);
        rep.authorizeProtocol(protocol1);
        vm.deal(external_, 10 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(rep.treasury(), treasury);
        assertEq(rep.owner(), owner);
        assertEq(rep.queryFee(), QUERY_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentReputation.ZeroAddress.selector);
        new AgentReputation(address(0), owner, QUERY_FEE);
    }

    // ─── Record Interaction ─────────────────────────────────────────────

    function test_recordPositive() public {
        vm.prank(protocol1);
        rep.recordInteraction(agent1, true, 0);
        assertEq(rep.getScoreFree(agent1), 110); // 100 base + 10
    }

    function test_recordNegative() public {
        vm.prank(protocol1);
        rep.recordInteraction(agent1, true, 0); // 110
        vm.prank(protocol1);
        rep.recordInteraction(agent1, false, 0); // 110 - 20 = 90
        assertEq(rep.getScoreFree(agent1), 90);
    }

    function test_scoreCannotGoBelowZero() public {
        vm.prank(protocol1);
        rep.recordInteraction(agent1, true, 0); // 110

        // 6 negatives: 110 - 120 would be negative, floors at 0
        for (uint i; i < 6; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, false, 0);
        }
        assertEq(rep.getScoreFree(agent1), 0);
    }

    function test_defaultScoreIs100() public view {
        assertEq(rep.getScoreFree(agent1), 100);
    }

    function test_multipleCategories() public {
        vm.startPrank(protocol1);
        rep.recordInteraction(agent1, true, 0); // PAYMENT
        rep.recordInteraction(agent1, true, 1); // ESCROW
        rep.recordInteraction(agent1, true, 4); // GENERAL
        vm.stopPrank();
        assertEq(rep.getScoreFree(agent1), 130); // 100 + 30
    }

    function test_revert_recordUnauthorized() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputation.NotAuthorizedProtocol.selector, external_));
        rep.recordInteraction(agent1, true, 0);
    }

    function test_revert_recordInvalidCategory() public {
        vm.prank(protocol1);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputation.InvalidCategory.selector, uint8(5)));
        rep.recordInteraction(agent1, true, 5);
    }

    function test_revert_recordZeroAgent() public {
        vm.prank(protocol1);
        vm.expectRevert(IAgentReputation.ZeroAddress.selector);
        rep.recordInteraction(address(0), true, 0);
    }

    function test_revert_recordWhenPaused() public {
        vm.prank(owner);
        rep.pause();

        vm.prank(protocol1);
        vm.expectRevert();
        rep.recordInteraction(agent1, true, 0);
    }

    // ─── Tiers ──────────────────────────────────────────────────────────

    function test_tierBronze() public view {
        assertEq(uint8(rep.getTierFree(agent1)), uint8(IAgentReputation.Tier.BRONZE)); // 100
    }

    function test_tierSilver() public {
        // need score >= 200, start at 100, need 10 positives
        for (uint i; i < 10; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, true, 0);
        }
        assertEq(rep.getScoreFree(agent1), 200);
        assertEq(uint8(rep.getTierFree(agent1)), uint8(IAgentReputation.Tier.SILVER));
    }

    function test_tierGold() public {
        for (uint i; i < 40; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, true, 0);
        }
        assertEq(rep.getScoreFree(agent1), 500);
        assertEq(uint8(rep.getTierFree(agent1)), uint8(IAgentReputation.Tier.GOLD));
    }

    function test_tierPlatinum() public {
        for (uint i; i < 90; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, true, 0);
        }
        assertEq(rep.getScoreFree(agent1), 1000);
        assertEq(uint8(rep.getTierFree(agent1)), uint8(IAgentReputation.Tier.PLATINUM));
    }

    // ─── Query Fees ─────────────────────────────────────────────────────

    function test_paidQueryReputation() public {
        vm.prank(external_);
        uint256 score = rep.getReputation{value: QUERY_FEE}(agent1);
        assertEq(score, 100);
        assertEq(rep.accumulatedFees(), QUERY_FEE);
    }

    function test_paidQueryTier() public {
        vm.prank(external_);
        IAgentReputation.Tier tier = rep.getReputationTier{value: QUERY_FEE}(agent1);
        assertEq(uint8(tier), uint8(IAgentReputation.Tier.BRONZE));
        assertEq(rep.accumulatedFees(), QUERY_FEE);
    }

    function test_freeQueryForAuthorized() public {
        vm.prank(protocol1);
        uint256 score = rep.getReputation(agent1);
        assertEq(score, 100);
        assertEq(rep.accumulatedFees(), 0);
    }

    function test_revert_queryInsufficientFee() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputation.InsufficientFee.selector, QUERY_FEE, 0));
        rep.getReputation(agent1);
    }

    // ─── Collect Fees ───────────────────────────────────────────────────

    function test_collectFees() public {
        vm.prank(external_);
        rep.getReputation{value: QUERY_FEE}(agent1);

        uint256 treasuryBefore = treasury.balance;
        rep.collectFees();

        assertEq(treasury.balance - treasuryBefore, QUERY_FEE);
        assertEq(rep.accumulatedFees(), 0);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentReputation.NoFeesToCollect.selector);
        rep.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizeProtocol() public {
        vm.prank(owner);
        rep.authorizeProtocol(protocol2);
        assertTrue(rep.isAuthorizedProtocol(protocol2));
    }

    function test_revokeProtocol() public {
        vm.prank(owner);
        rep.revokeProtocol(protocol1);
        assertFalse(rep.isAuthorizedProtocol(protocol1));
    }

    function test_revert_authorizeZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentReputation.ZeroAddress.selector);
        rep.authorizeProtocol(address(0));
    }

    function test_revert_authorizeDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputation.AlreadyAuthorized.selector, protocol1));
        rep.authorizeProtocol(protocol1);
    }

    function test_revert_revokeNotAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputation.NotAuthorized.selector, protocol2));
        rep.revokeProtocol(protocol2);
    }

    function test_setQueryFee() public {
        vm.prank(owner);
        rep.setQueryFee(0.002 ether);
        assertEq(rep.queryFee(), 0.002 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        rep.setTreasury(newT);
        assertEq(rep.treasury(), newT);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_positiveInteractions(uint8 count) public {
        count = uint8(bound(count, 1, 200));
        for (uint i; i < count; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, true, 0);
        }
        assertEq(rep.getScoreFree(agent1), 100 + uint256(count) * 10);
    }

    function testFuzz_negativeNeverBelowZero(uint8 count) public {
        count = uint8(bound(count, 1, 200));
        for (uint i; i < count; i++) {
            vm.prank(protocol1);
            rep.recordInteraction(agent1, false, 0);
        }
        // score starts at 100, each negative -20, floors at 0
        uint256 expected = count >= 5 ? 0 : 100 - uint256(count) * 20;
        assertEq(rep.getScoreFree(agent1), expected);
    }

    function testFuzz_queryFeeAccumulates(uint8 queries) public {
        queries = uint8(bound(queries, 1, 50));
        for (uint i; i < queries; i++) {
            vm.prank(external_);
            rep.getReputation{value: QUERY_FEE}(agent1);
        }
        assertEq(rep.accumulatedFees(), uint256(queries) * QUERY_FEE);
    }
}
