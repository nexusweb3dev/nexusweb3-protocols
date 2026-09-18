// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentReputationV2} from "../../src/v2/AgentReputationV2.sol";
import {IAgentReputationV2} from "../../src/v2/interfaces/IAgentReputationV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract AgentReputationV2Test is Test {
    AgentReputationV2 rep;

    address owner = makeAddr("owner");
    address protocol1 = makeAddr("protocol1");
    address protocol2 = makeAddr("protocol2");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address external_ = makeAddr("external");

    uint256 constant UNIT = 100e6; // $100 USDC

    function setUp() public {
        rep = new AgentReputationV2(owner);
        vm.prank(owner);
        rep.authorizeProtocol(protocol1);
    }

    function _record(address agent, bool positive, uint256 value) internal {
        vm.prank(protocol1);
        rep.recordInteraction(agent, positive, 0, value);
    }

    function _recordMany(address agent, bool positive, uint256 count) internal {
        vm.startPrank(protocol1);
        for (uint256 i; i < count; ++i) {
            rep.recordInteraction(agent, positive, 0, 0);
        }
        vm.stopPrank();
    }

    // ─── Constructor / constants ────────────────────────────────────────

    function test_constructor() public view {
        assertEq(rep.owner(), owner);
        assertFalse(rep.paused());
        assertTrue(rep.isAuthorizedProtocol(protocol1));
        assertFalse(rep.isAuthorizedProtocol(protocol2));
    }

    function test_constants() public view {
        assertEq(rep.BASE_SCORE(), 100);
        assertEq(rep.POSITIVE_POINTS(), 10);
        assertEq(rep.NEGATIVE_POINTS(), 20);
        assertEq(rep.VOLUME_UNIT(), UNIT);
        assertEq(rep.MAX_CATEGORY(), 4);
    }

    // ─── Record ─────────────────────────────────────────────────────────

    function test_recordPositiveUpdatesStats() public {
        vm.warp(1000);
        _record(agent1, true, 250e6);

        IAgentReputationV2.Stats memory s = rep.getStats(agent1);
        assertEq(s.positives, 1);
        assertEq(s.negatives, 0);
        assertEq(s.volumeUsdc, 250e6);
        assertEq(s.firstSeen, 1000);
        assertEq(s.lastActivity, 1000);
    }

    function test_firstSeenStickyLastActivityMoves() public {
        vm.warp(1000);
        _record(agent1, true, 0);
        vm.warp(5000);
        _record(agent1, true, 0);

        IAgentReputationV2.Stats memory s = rep.getStats(agent1);
        assertEq(s.firstSeen, 1000);
        assertEq(s.lastActivity, 5000);
        assertEq(s.positives, 2);
    }

    function test_negativeDoesNotAddVolume() public {
        _record(agent1, false, 10_000e6);
        IAgentReputationV2.Stats memory s = rep.getStats(agent1);
        assertEq(s.negatives, 1);
        assertEq(s.volumeUsdc, 0);
        assertEq(rep.getScore(agent1), 80); // 100 - 20, no volume credit
    }

    function test_allCategoriesAccepted() public {
        vm.startPrank(protocol1);
        for (uint8 c; c <= 4; ++c) {
            rep.recordInteraction(agent1, true, c, 0);
        }
        vm.stopPrank();
        assertEq(rep.getStats(agent1).positives, 5);
        assertEq(rep.getScore(agent1), 150);
    }

    function test_agentsAreIndependent() public {
        _record(agent1, true, 0);
        assertEq(rep.getScore(agent1), 110);
        assertEq(rep.getScore(agent2), 100);
        assertEq(rep.getStats(agent2).firstSeen, 0);
    }

    function test_volumeSaturatesAtUint128Max() public {
        _record(agent1, true, type(uint256).max);
        assertEq(rep.getStats(agent1).volumeUsdc, type(uint128).max);

        // Second max-value record must not revert and must stay saturated.
        _record(agent1, true, type(uint256).max);
        assertEq(rep.getStats(agent1).volumeUsdc, type(uint128).max);
        assertEq(rep.getStats(agent1).positives, 2);
    }

    function test_revert_recordUnauthorized() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.NotAuthorizedProtocol.selector, external_));
        rep.recordInteraction(agent1, true, 0, 0);
    }

    function test_revert_recordZeroAgent() public {
        vm.prank(protocol1);
        vm.expectRevert(IAgentReputationV2.ZeroAddress.selector);
        rep.recordInteraction(address(0), true, 0, 0);
    }

    function test_revert_recordInvalidCategory() public {
        vm.prank(protocol1);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.InvalidCategory.selector, uint8(5)));
        rep.recordInteraction(agent1, true, 5, 0);
    }

    function test_revert_recordAfterRevoke() public {
        vm.prank(owner);
        rep.revokeProtocol(protocol1);
        vm.prank(protocol1);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.NotAuthorizedProtocol.selector, protocol1));
        rep.recordInteraction(agent1, true, 0, 0);
    }

    // ─── Score math ─────────────────────────────────────────────────────

    function test_unknownAgentScoresBase() public view {
        assertEq(rep.getScore(agent1), 100);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.BRONZE));
    }

    function test_volumePointsRoundDown() public {
        _record(agent1, true, 199e6); // 1 positive (+10) + 1 volume point
        assertEq(rep.getScore(agent1), 111);
    }

    function test_volumeBelowUnitAddsNothing() public {
        _record(agent1, true, UNIT - 1);
        assertEq(rep.getScore(agent1), 110);
    }

    function test_mixedPositivesAndNegatives() public {
        _recordMany(agent1, true, 5); // +50
        _recordMany(agent1, false, 2); // -40
        assertEq(rep.getScore(agent1), 110); // 100 + 50 - 40
    }

    function test_scoreFloorsAtZero() public {
        _recordMany(agent1, true, 1); // 110
        _recordMany(agent1, false, 20); // -400 -> would be negative
        assertEq(rep.getScore(agent1), 0);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.BRONZE));
    }

    function test_scoreExactlyZeroBoundary() public {
        _recordMany(agent1, false, 5); // 100 - 100 = 0
        assertEq(rep.getScore(agent1), 0);
        _recordMany(agent1, false, 1); // stays floored
        assertEq(rep.getScore(agent1), 0);
    }

    function test_volumeThenNegativesStillFloors() public {
        _record(agent1, true, 1000e6); // 100 + 10 + 10 = 120
        assertEq(rep.getScore(agent1), 120);
        _recordMany(agent1, false, 6); // -120
        assertEq(rep.getScore(agent1), 0);
    }

    // ─── Tiers ──────────────────────────────────────────────────────────

    function test_tierBronzeBelow200() public {
        _recordMany(agent1, true, 9); // 190
        assertEq(rep.getScore(agent1), 190);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.BRONZE));
    }

    function test_tierSilverAtExactly200() public {
        _recordMany(agent1, true, 10); // 200
        assertEq(rep.getScore(agent1), 200);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.SILVER));
    }

    function test_tierGoldAtExactly500() public {
        _record(agent1, true, 39_000e6); // 100 + 10 + 390 = 500
        assertEq(rep.getScore(agent1), 500);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.GOLD));
    }

    function test_tierGoldJustBelowAtFourNinetyNine() public {
        _record(agent1, true, 38_900e6); // 100 + 10 + 389 = 499
        assertEq(rep.getScore(agent1), 499);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.SILVER));
    }

    function test_tierPlatinumAtExactly1000() public {
        _record(agent1, true, 89_000e6); // 100 + 10 + 890 = 1000
        assertEq(rep.getScore(agent1), 1000);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.PLATINUM));
    }

    function test_tierPlatinumJustBelowAtNineNinetyNine() public {
        _record(agent1, true, 88_900e6); // 999
        assertEq(rep.getScore(agent1), 999);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.GOLD));
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizeProtocol() public {
        vm.prank(owner);
        rep.authorizeProtocol(protocol2);
        assertTrue(rep.isAuthorizedProtocol(protocol2));

        vm.prank(protocol2);
        rep.recordInteraction(agent1, true, 0, 0);
        assertEq(rep.getScore(agent1), 110);
    }

    function test_revokeProtocol() public {
        vm.prank(owner);
        rep.revokeProtocol(protocol1);
        assertFalse(rep.isAuthorizedProtocol(protocol1));
    }

    function test_revert_authorizeZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAgentReputationV2.ZeroAddress.selector);
        rep.authorizeProtocol(address(0));
    }

    function test_revert_authorizeAlreadyAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.AlreadyAuthorized.selector, protocol1));
        rep.authorizeProtocol(protocol1);
    }

    function test_revert_revokeNotAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.NotAuthorized.selector, protocol2));
        rep.revokeProtocol(protocol2);
    }

    function test_revert_authorizeNotOwner() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, external_));
        rep.authorizeProtocol(protocol2);
    }

    function test_revert_revokeNotOwner() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, external_));
        rep.revokeProtocol(protocol1);
    }

    function test_revert_pauseNotOwner() public {
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, external_));
        rep.pause();
    }

    function test_revert_unpauseNotOwner() public {
        vm.prank(owner);
        rep.pause();
        vm.prank(external_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, external_));
        rep.unpause();
    }

    // ─── Pause ──────────────────────────────────────────────────────────

    function test_revert_recordWhenPaused() public {
        vm.prank(owner);
        rep.pause();
        assertTrue(rep.paused());

        vm.prank(protocol1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        rep.recordInteraction(agent1, true, 0, 0);
    }

    function test_readsWorkWhilePaused() public {
        _record(agent1, true, 500e6); // 100 + 10 + 5 = 115
        vm.prank(owner);
        rep.pause();

        assertEq(rep.getScore(agent1), 115);
        assertEq(uint8(rep.getTier(agent1)), uint8(IAgentReputationV2.Tier.BRONZE));
        assertEq(rep.getStats(agent1).positives, 1);
        assertTrue(rep.isAuthorizedProtocol(protocol1));
    }

    function test_unpauseRestoresRecording() public {
        vm.prank(owner);
        rep.pause();
        vm.prank(owner);
        rep.unpause();
        assertFalse(rep.paused());

        _record(agent1, true, 0);
        assertEq(rep.getScore(agent1), 110);
    }

    // ─── Events ─────────────────────────────────────────────────────────

    function test_emitInteractionRecorded() public {
        vm.expectEmit(true, true, true, true, address(rep));
        emit IAgentReputationV2.InteractionRecorded(agent1, protocol1, true, 2, 750e6);
        vm.prank(protocol1);
        rep.recordInteraction(agent1, true, 2, 750e6);
    }

    function test_emitInteractionRecordedNegative() public {
        vm.expectEmit(true, true, true, true, address(rep));
        emit IAgentReputationV2.InteractionRecorded(agent1, protocol1, false, 4, 1);
        vm.prank(protocol1);
        rep.recordInteraction(agent1, false, 4, 1);
    }

    function test_emitProtocolAuthorized() public {
        vm.expectEmit(true, false, false, true, address(rep));
        emit IAgentReputationV2.ProtocolAuthorized(protocol2);
        vm.prank(owner);
        rep.authorizeProtocol(protocol2);
    }

    function test_emitProtocolRevoked() public {
        vm.expectEmit(true, false, false, true, address(rep));
        emit IAgentReputationV2.ProtocolRevoked(protocol1);
        vm.prank(owner);
        rep.revokeProtocol(protocol1);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_scoreFormula(uint8 rawPositives, uint8 rawNegatives) public {
        uint256 positives = bound(rawPositives, 0, 60);
        uint256 negatives = bound(rawNegatives, 0, 60);
        _recordMany(agent1, true, positives);
        _recordMany(agent1, false, negatives);

        uint256 gains = 100 + 10 * positives;
        uint256 losses = 20 * negatives;
        uint256 expected = gains > losses ? gains - losses : 0;
        assertEq(rep.getScore(agent1), expected);
    }

    function testFuzz_scoreMonotonicInValue(uint128 a, uint128 b) public {
        vm.assume(a <= b);
        _record(agent1, true, a);
        _record(agent2, true, b);
        assertLe(rep.getScore(agent1), rep.getScore(agent2));
    }

    function testFuzz_volumeNeverReverts(uint256 v1, uint256 v2) public {
        _record(agent1, true, v1);
        _record(agent1, true, v2);

        uint256 sum = v1 > type(uint256).max - v2 ? type(uint256).max : v1 + v2;
        uint256 expected = sum > type(uint128).max ? type(uint128).max : sum;
        assertEq(rep.getStats(agent1).volumeUsdc, expected);
    }

    function testFuzz_tierMatchesScore(uint8 rawPositives, uint64 value) public {
        _recordMany(agent1, true, bound(rawPositives, 0, 60));
        _record(agent1, true, value);

        uint256 score = rep.getScore(agent1);
        IAgentReputationV2.Tier tier = rep.getTier(agent1);
        if (score >= 1000) {
            assertEq(uint8(tier), uint8(IAgentReputationV2.Tier.PLATINUM));
        } else if (score >= 500) {
            assertEq(uint8(tier), uint8(IAgentReputationV2.Tier.GOLD));
        } else if (score >= 200) {
            assertEq(uint8(tier), uint8(IAgentReputationV2.Tier.SILVER));
        } else {
            assertEq(uint8(tier), uint8(IAgentReputationV2.Tier.BRONZE));
        }
    }

    function testFuzz_onlyAuthorizedCanRecord(address caller) public {
        vm.assume(caller != protocol1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAgentReputationV2.NotAuthorizedProtocol.selector, caller));
        rep.recordInteraction(agent1, true, 0, 0);
    }
}
