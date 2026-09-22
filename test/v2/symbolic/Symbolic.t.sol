// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {AgentReputationV2} from "../../../src/v2/AgentReputationV2.sol";
import {AgentKillSwitchV2} from "../../../src/v2/AgentKillSwitchV2.sol";
import {FeeRouter} from "../../../src/v2/FeeRouter.sol";
import {IAgentReputationV2} from "../../../src/v2/interfaces/IAgentReputationV2.sol";

/// @notice Symbolic execution targets for Halmos (`halmos --match-contract Symbolic --function check_`).
///         These prove arithmetic properties for ALL inputs, not sampled ones. Also runnable by forge
///         as ordinary tests with concrete fuzzing (`check_` functions are picked up by `forge test`
///         only if prefixed `test`, so each has a thin `test_` wrapper for CI).
contract SymbolicTest is Test {
    address owner = address(0xA11CE);
    address protocol = address(0xB0B);
    address agent = address(0xCAFE);

    // ─── FeeRouter: split conservation for every amount and split ─────────

    function check_feeRouter_split_conserves(uint256 amount, uint16 stakingBps) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(stakingBps <= 10_000);
        uint16 treasuryBps = 10_000 - stakingBps;
        ERC20Mock usdc = new ERC20Mock("U", "U", 6);
        address treasury = address(0x7);
        address staking = address(0x8);
        FeeRouter r =
            new FeeRouter(IERC20(address(usdc)), owner, treasury, staking, address(0), stakingBps, treasuryBps);
        vm.prank(owner);
        r.authorizeProtocol(protocol);
        usdc.mint(address(r), amount);
        vm.prank(protocol);
        r.route(agent, amount);
        assert(usdc.balanceOf(treasury) + usdc.balanceOf(staking) == amount);
        assert(usdc.balanceOf(address(r)) == 0);
    }

    function test_feeRouter_split_conserves(uint128 amount, uint16 stakingBps) public {
        amount = uint128(bound(amount, 1, type(uint128).max - 1));
        stakingBps = uint16(bound(stakingBps, 0, 10_000));
        check_feeRouter_split_conserves(amount, stakingBps);
    }

    // ─── Reputation: score formula bounded and monotone in positives ─────

    function check_reputation_score_bounds(uint8 positives, uint8 negatives, uint128 value) public {
        AgentReputationV2 rep = new AgentReputationV2(owner);
        vm.prank(owner);
        rep.authorizeProtocol(protocol);
        vm.startPrank(protocol);
        for (uint256 i = 0; i < positives; i++) {
            rep.recordInteraction(agent, true, 1, value);
        }
        for (uint256 i = 0; i < negatives; i++) {
            rep.recordInteraction(agent, false, 1, value);
        }
        vm.stopPrank();
        uint256 score = rep.getScore(agent);
        IAgentReputationV2.Stats memory s = rep.getStats(agent);
        // volume only from positives, saturating
        uint256 expectedVolume = uint256(value) * positives;
        if (expectedVolume > type(uint128).max) expectedVolume = type(uint128).max;
        assert(s.volumeUsdc == expectedVolume);
        uint256 gains = 100 + 10 * uint256(positives) + expectedVolume / 100e6;
        uint256 losses = 20 * uint256(negatives);
        assert(score == (gains > losses ? gains - losses : 0));
        // never negative, never exceeds gains
        assert(score <= gains);
    }

    function test_reputation_score_bounds(uint8 positives, uint8 negatives, uint128 value) public {
        positives = uint8(bound(positives, 0, 6));
        negatives = uint8(bound(negatives, 0, 6));
        check_reputation_score_bounds(positives, negatives, value);
    }

    // ─── KillSwitch: consume never exceeds limit, session roll resets ────

    function check_killSwitch_consume_bounded(uint128 limit, uint128 a1, uint128 a2, uint32 txLimit) public {
        vm.assume(limit > 0);
        AgentKillSwitchV2 ks = new AgentKillSwitchV2(owner);
        vm.prank(owner);
        ks.authorizeProtocol(protocol);
        vm.prank(agent);
        ks.register(limit, txLimit, 1 days);

        vm.startPrank(protocol);
        (bool ok1,) = address(ks).call(abi.encodeCall(ks.consume, (agent, a1)));
        (bool ok2,) = address(ks).call(abi.encodeCall(ks.consume, (agent, a2)));
        vm.stopPrank();

        uint256 spent = ks.getConfig(agent).spent;
        assert(spent <= limit);
        // success iff cumulative within limit and within tx limit
        bool within1 = a1 <= limit && (txLimit == 0 || txLimit >= 1);
        assert(ok1 == within1);
        if (ok1) {
            bool within2 = uint256(a1) + a2 <= limit && (txLimit == 0 || txLimit >= 2);
            assert(ok2 == within2);
            assert(spent == (ok2 ? uint256(a1) + a2 : a1));
        } else {
            bool within2 = a2 <= limit && (txLimit == 0 || txLimit >= 1);
            assert(ok2 == within2);
            assert(spent == (ok2 ? a2 : 0));
        }
        assert(ks.remainingSpend(agent) == limit - spent);

        // After the session rolls, the full limit is available again.
        vm.warp(block.timestamp + 1 days);
        assert(ks.remainingSpend(agent) == limit);
    }

    function test_killSwitch_consume_bounded(uint128 limit, uint128 a1, uint128 a2, uint32 txLimit) public {
        limit = uint128(bound(limit, 1, type(uint128).max));
        check_killSwitch_consume_bounded(limit, a1, a2, txLimit);
    }
}
