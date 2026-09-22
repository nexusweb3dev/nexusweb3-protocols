// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";
import {OperatorGated} from "../../src/v2/OperatorGated.sol";

contract Gated is OperatorGated {
    constructor(IAgentAccess a) OperatorGated(a) {}

    function act(address agent) external view onlyAgentOrOperator(agent) returns (bool) {
        return true;
    }
}

contract AgentAccessTest is Test {
    AgentAccess acc;

    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");
    address stranger = makeAddr("stranger");

    uint48 constant NO_EXPIRY = type(uint48).max;

    function setUp() public {
        acc = new AgentAccess();
        vm.warp(1000);
    }

    function _authorize(address agent, address operator, uint48 expiry) internal {
        vm.prank(agent);
        acc.authorizeOperator(operator, expiry);
    }

    // ─── authorizeOperator ──────────────────────────────────────────────

    function test_authorizeOperatorHappyPath() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        _authorize(agent1, operator1, expiry);

        assertEq(acc.operatorExpiry(agent1, operator1), expiry);
        assertTrue(acc.isOperatorFor(agent1, operator1));
    }

    function test_authorizeOperatorEmitsEvent() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        vm.expectEmit(true, true, false, true, address(acc));
        emit IAgentAccess.OperatorAuthorized(agent1, operator1, expiry);
        _authorize(agent1, operator1, expiry);
    }

    function test_reauthorizeUpdatesExpiryLonger() public {
        uint48 first = uint48(block.timestamp + 1 days);
        uint48 second = uint48(block.timestamp + 30 days);
        _authorize(agent1, operator1, first);
        _authorize(agent1, operator1, second);

        assertEq(acc.operatorExpiry(agent1, operator1), second);
    }

    function test_reauthorizeUpdatesExpiryShorter() public {
        uint48 first = uint48(block.timestamp + 30 days);
        uint48 second = uint48(block.timestamp + 1 days);
        _authorize(agent1, operator1, first);
        _authorize(agent1, operator1, second);

        assertEq(acc.operatorExpiry(agent1, operator1), second);
    }

    function test_reauthorizeEmitsEventWithNewExpiry() public {
        uint48 first = uint48(block.timestamp + 1 days);
        uint48 second = uint48(block.timestamp + 2 days);
        _authorize(agent1, operator1, first);

        vm.expectEmit(true, true, false, true, address(acc));
        emit IAgentAccess.OperatorAuthorized(agent1, operator1, second);
        _authorize(agent1, operator1, second);
    }

    function test_authorizeOperatorRevertsZeroAddress() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAccess.ZeroAddress.selector);
        acc.authorizeOperator(address(0), uint48(block.timestamp + 1 days));
    }

    function test_authorizeOperatorRevertsSelfOperator() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentAccess.SelfOperator.selector);
        acc.authorizeOperator(agent1, uint48(block.timestamp + 1 days));
    }

    function test_authorizeOperatorRevertsExpiryEqualToNow() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.ExpiryInPast.selector, uint48(block.timestamp)));
        acc.authorizeOperator(operator1, uint48(block.timestamp));
    }

    function test_authorizeOperatorRevertsExpiryInPast() public {
        vm.warp(block.timestamp + 100);
        uint48 pastExpiry = uint48(block.timestamp - 50);
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.ExpiryInPast.selector, pastExpiry));
        acc.authorizeOperator(operator1, pastExpiry);
    }

    function test_authorizeOperatorSucceedsAtNowPlusOne() public {
        uint48 expiry = uint48(block.timestamp + 1);
        _authorize(agent1, operator1, expiry);
        assertEq(acc.operatorExpiry(agent1, operator1), expiry);
    }

    // ─── revokeOperator ─────────────────────────────────────────────────

    function test_revokeOperatorHappyPath() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));

        vm.prank(agent1);
        acc.revokeOperator(operator1);

        assertEq(acc.operatorExpiry(agent1, operator1), 0);
        assertFalse(acc.isOperatorFor(agent1, operator1));
    }

    function test_revokeOperatorEmitsEvent() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));

        vm.expectEmit(true, true, false, true, address(acc));
        emit IAgentAccess.OperatorRevoked(agent1, operator1);
        vm.prank(agent1);
        acc.revokeOperator(operator1);
    }

    function test_revokeOperatorRevertsNotOperatorUnknown() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, agent1, operator1));
        acc.revokeOperator(operator1);
    }

    function test_revokeOperatorRevertsNotOperatorDoubleRevoke() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));

        vm.prank(agent1);
        acc.revokeOperator(operator1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, agent1, operator1));
        acc.revokeOperator(operator1);
    }

    function test_revokeThenReauthorizeWorks() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        vm.prank(agent1);
        acc.revokeOperator(operator1);

        uint48 newExpiry = uint48(block.timestamp + 5 days);
        _authorize(agent1, operator1, newExpiry);
        assertEq(acc.operatorExpiry(agent1, operator1), newExpiry);
    }

    // ─── isOperatorFor ──────────────────────────────────────────────────

    function test_isOperatorForAgentItselfAlwaysTrue() public view {
        assertTrue(acc.isOperatorFor(agent1, agent1));
    }

    function test_isOperatorForZeroAddressAgentAndCaller() public view {
        // caller == agent short-circuit applies even for the zero address on both sides.
        assertTrue(acc.isOperatorFor(address(0), address(0)));
    }

    function test_isOperatorForZeroAddressCallerNotAgent() public view {
        // Zero address caller with no authorization and not equal to the agent is not an operator.
        assertFalse(acc.isOperatorFor(agent1, address(0)));
    }

    function test_isOperatorForTrueBeforeExpiry() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        _authorize(agent1, operator1, expiry);

        vm.warp(expiry - 1);
        assertTrue(acc.isOperatorFor(agent1, operator1));
    }

    function test_isOperatorForFalseAtExactExpiry() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        _authorize(agent1, operator1, expiry);

        vm.warp(expiry);
        assertFalse(acc.isOperatorFor(agent1, operator1));
    }

    function test_isOperatorForFalseAfterExpiry() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        _authorize(agent1, operator1, expiry);

        vm.warp(expiry + 1);
        assertFalse(acc.isOperatorFor(agent1, operator1));
    }

    function test_isOperatorForFalseAfterRevoke() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        vm.prank(agent1);
        acc.revokeOperator(operator1);

        assertFalse(acc.isOperatorFor(agent1, operator1));
    }

    function test_isOperatorForFalseForUnrelatedCaller() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        assertFalse(acc.isOperatorFor(agent1, stranger));
    }

    function test_isOperatorForFalseForUnauthorizedOperatorOnDifferentAgent() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        assertFalse(acc.isOperatorFor(agent2, operator1));
    }

    function test_maxExpiryNeverExpires() public {
        _authorize(agent1, operator1, NO_EXPIRY);

        vm.warp(block.timestamp + 100 * 365 days);
        assertTrue(acc.isOperatorFor(agent1, operator1));
    }

    // ─── operatorExpiry ─────────────────────────────────────────────────

    function test_operatorExpiryZeroWhenUnauthorized() public view {
        assertEq(acc.operatorExpiry(agent1, operator1), 0);
    }

    function test_operatorExpiryReflectsAuthorization() public {
        uint48 expiry = uint48(block.timestamp + 42 days);
        _authorize(agent1, operator1, expiry);
        assertEq(acc.operatorExpiry(agent1, operator1), expiry);
    }

    // ─── Operators cannot chain / independence across principals ───────

    function test_operatorsCannotChain() public {
        // A authorizes B; B authorizes C. C must NOT be an operator for A.
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        _authorize(operator1, operator2, uint48(block.timestamp + 1 days));

        assertTrue(acc.isOperatorFor(agent1, operator1));
        assertTrue(acc.isOperatorFor(operator1, operator2));
        assertFalse(acc.isOperatorFor(agent1, operator2));
    }

    function test_authorizationsAreIndependentAcrossPrincipals() public {
        _authorize(agent1, operator1, uint48(block.timestamp + 1 days));
        _authorize(agent2, operator1, uint48(block.timestamp + 10 days));

        assertEq(acc.operatorExpiry(agent1, operator1), uint48(block.timestamp + 1 days));
        assertEq(acc.operatorExpiry(agent2, operator1), uint48(block.timestamp + 10 days));

        vm.prank(agent1);
        acc.revokeOperator(operator1);

        assertFalse(acc.isOperatorFor(agent1, operator1));
        assertTrue(acc.isOperatorFor(agent2, operator1));
    }

    function test_sameOperatorMultipleAgentsIndependentRevocation() public {
        _authorize(agent1, operator2, uint48(block.timestamp + 1 days));
        _authorize(agent2, operator2, uint48(block.timestamp + 1 days));

        vm.prank(agent2);
        acc.revokeOperator(operator2);

        assertTrue(acc.isOperatorFor(agent1, operator2));
        assertFalse(acc.isOperatorFor(agent2, operator2));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_authorizeThenIsOperatorForMatchesExpirySemantics(uint48 offset, uint48 warpOffset) public {
        offset = uint48(bound(offset, 1, type(uint48).max - block.timestamp));
        uint48 expiry = uint48(block.timestamp + offset);
        _authorize(agent1, operator1, expiry);

        warpOffset = uint48(bound(warpOffset, 0, offset + 100));
        uint256 newTime = block.timestamp + warpOffset;
        vm.warp(newTime);

        bool expected = newTime < expiry;
        assertEq(acc.isOperatorFor(agent1, operator1), expected);
    }

    function testFuzz_randomOperatorAgentPairsIndependent(address a, address b, address c, address d) public {
        vm.assume(a != b && c != d);
        vm.assume(a != c || b != d);

        uint48 expiryAb = uint48(block.timestamp + 1 days);
        if (a != address(0) && b != address(0) && a != b) {
            _authorize(a, b, expiryAb);
            assertTrue(acc.isOperatorFor(a, b));
        }

        if (c != address(0) && d != address(0) && c != d && (a != c || b != d)) {
            assertEq(acc.operatorExpiry(c, d), 0);
        }
    }

    function testFuzz_revokeAtAnyWarpOffsetClearsAuthorization(uint48 offset, uint48 warpOffset) public {
        offset = uint48(bound(offset, 1, type(uint48).max - block.timestamp));
        uint48 expiry = uint48(block.timestamp + offset);
        _authorize(agent1, operator1, expiry);

        warpOffset = uint48(bound(warpOffset, 0, 1000 days));
        vm.warp(block.timestamp + warpOffset);

        vm.prank(agent1);
        acc.revokeOperator(operator1);

        assertEq(acc.operatorExpiry(agent1, operator1), 0);
        assertFalse(acc.isOperatorFor(agent1, operator1));
    }

    function testFuzz_reauthorizeAlwaysStoresLatestExpiry(uint48 firstOffset, uint48 secondOffset) public {
        firstOffset = uint48(bound(firstOffset, 1, type(uint48).max - block.timestamp));
        secondOffset = uint48(bound(secondOffset, 1, type(uint48).max - block.timestamp));

        uint48 firstExpiry = uint48(block.timestamp + firstOffset);
        uint48 secondExpiry = uint48(block.timestamp + secondOffset);

        _authorize(agent1, operator1, firstExpiry);
        _authorize(agent1, operator1, secondExpiry);

        assertEq(acc.operatorExpiry(agent1, operator1), secondExpiry);
    }
}

contract OperatorGatedTest is Test {
    AgentAccess acc;
    Gated gated;

    address agent1 = makeAddr("agent1");
    address operator1 = makeAddr("operator1");
    address stranger = makeAddr("stranger");

    function setUp() public {
        acc = new AgentAccess();
        gated = new Gated(IAgentAccess(address(acc)));
        vm.warp(1000);
    }

    function test_constructorRevertsZeroAccess() public {
        vm.expectRevert(OperatorGated.ZeroAccess.selector);
        new Gated(IAgentAccess(address(0)));
    }

    function test_accessGetterReturnsRegistry() public view {
        assertEq(address(gated.access()), address(acc));
    }

    function test_modifierPassesForPrincipal() public {
        vm.prank(agent1);
        assertTrue(gated.act(agent1));
    }

    function test_modifierPassesForOperator() public {
        vm.prank(agent1);
        acc.authorizeOperator(operator1, uint48(block.timestamp + 1 days));

        vm.prank(operator1);
        assertTrue(gated.act(agent1));
    }

    function test_modifierRevertsForUnrelatedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, agent1, stranger));
        gated.act(agent1);
    }

    function test_modifierRevertsAfterExpiry() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        vm.prank(agent1);
        acc.authorizeOperator(operator1, expiry);

        vm.warp(expiry);
        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, agent1, operator1));
        gated.act(agent1);
    }

    function test_modifierRevertsAfterRevoke() public {
        vm.prank(agent1);
        acc.authorizeOperator(operator1, uint48(block.timestamp + 1 days));
        vm.prank(agent1);
        acc.revokeOperator(operator1);

        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, agent1, operator1));
        gated.act(agent1);
    }

    function testFuzz_modifierMatchesIsOperatorFor(address caller, uint48 offset) public {
        offset = uint48(bound(offset, 1, type(uint48).max - block.timestamp));
        vm.assume(caller != operator1 && caller != address(0));

        vm.prank(agent1);
        acc.authorizeOperator(operator1, uint48(block.timestamp + offset));

        bool shouldPass = acc.isOperatorFor(agent1, caller);
        vm.prank(caller);
        if (shouldPass) {
            assertTrue(gated.act(agent1));
        } else {
            vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, agent1, caller));
            gated.act(agent1);
        }
    }
}
