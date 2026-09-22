// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {IAgentEscrowV2} from "../../../src/v2/interfaces/IAgentEscrowV2.sol";
import {IAgentKillSwitchV2} from "../../../src/v2/interfaces/IAgentKillSwitchV2.sol";

/// @notice Stateful invariants over random sequences of every escrow entrypoint (see EscrowHandler).
///         Run with a higher budget before deploy: `forge test --match-path 'test/v2/invariants/*'
///         --fuzz-runs 2000` (invariant runs/depth configured in foundry.toml [invariant]).
contract EscrowInvariants is Test {
    EscrowHandler h;

    function setUp() public {
        h = new EscrowHandler();
        targetContract(address(h));
    }

    /// @dev The escrow never holds less than it owes, and never more than it received.
    function invariant_solvency() public view {
        uint256 owed;
        uint256 n = h.escrow().jobCount();
        for (uint256 i = 0; i < n; i++) {
            IAgentEscrowV2.Job memory j = h.escrow().getJob(i);
            owed += j.total - j.released - j.refunded;
        }
        uint256 claimable;
        for (uint256 i = 0; i < h.actorCount(); i++) {
            claimable += h.escrow().claimable(h.actors(i));
        }
        claimable += h.escrow().claimable(h.owner());
        assertEq(h.usdc().balanceOf(address(h.escrow())), owed + claimable, "escrow balance != owed + claimable");
    }

    /// @dev Money conservation: everything deposited is either still owed, parked, or paid out.
    function invariant_conservation() public view {
        assertEq(
            h.ghostDeposited(),
            h.usdc().balanceOf(address(h.escrow())) + h.ghostPaidOut(),
            "deposited != balance + paidOut"
        );
    }

    /// @dev Per-job accounting can never exceed the deposit, and terminal states are fully settled.
    function invariant_jobAccounting() public view {
        uint256 n = h.escrow().jobCount();
        for (uint256 i = 0; i < n; i++) {
            _checkJob(i);
        }
    }

    function _checkJob(uint256 i) internal view {
        IAgentEscrowV2.Job memory j = h.escrow().getJob(i);
        assertLe(j.released + j.refunded, j.total, "over-settled");
        assertLe(j.approvedCount, j.milestoneCount, "approvedCount > milestoneCount");
        (uint256 approvedSum, uint256 approvedN) = _approved(i);
        assertEq(approvedN, j.approvedCount, "approvedCount drift");
        bool live = j.status == IAgentEscrowV2.JobStatus.Open || j.status == IAgentEscrowV2.JobStatus.Disputed;
        if (live) {
            assertEq(j.released, approvedSum, "released != sum(approved) while live");
            assertEq(j.refunded, 0, "refund before terminal");
        } else {
            assertEq(j.released + j.refunded, j.total, "terminal job not fully settled");
            assertGe(j.released, approvedSum, "released < sum(approved) at terminal");
        }
        if (j.status == IAgentEscrowV2.JobStatus.Completed) {
            assertEq(j.approvedCount, j.milestoneCount, "completed without all approvals");
            assertEq(j.refunded, 0, "completed job refunded");
        }
        if (j.status == IAgentEscrowV2.JobStatus.Cancelled) assertEq(j.released, 0, "cancelled job released funds");
    }

    function _approved(uint256 i) internal view returns (uint256 sum, uint256 count) {
        IAgentEscrowV2.Milestone[] memory ms = h.escrow().getMilestones(i);
        for (uint256 k = 0; k < ms.length; k++) {
            if (ms[k].status == IAgentEscrowV2.MilestoneStatus.Approved) {
                sum += ms[k].amount;
                count++;
            }
        }
    }

    /// @dev Kill-switch spend counters never exceed the configured limit within a session.
    function invariant_killSwitchBounds() public view {
        for (uint256 i = 0; i < 2; i++) {
            IAgentKillSwitchV2.AgentConfig memory c = h.killSwitch().getConfig(h.actors(i));
            assertLe(c.spent, c.spendingLimit, "spent > limit");
            if (c.txLimit != 0) assertLe(c.txCount, c.txLimit, "txCount > txLimit");
        }
    }

    /// @dev Reputation positives for the provider of a job never exceed milestones ever approved
    ///      plus dispute wins, so the escrow cannot mint reputation out of thin air.
    function invariant_reputationBoundedByWork() public view {
        uint256 n = h.escrow().jobCount();
        uint256 totalApproved;
        uint256 totalResolved;
        for (uint256 i = 0; i < n; i++) {
            IAgentEscrowV2.Job memory j = h.escrow().getJob(i);
            totalApproved += j.approvedCount;
            if (j.status == IAgentEscrowV2.JobStatus.Resolved || j.status == IAgentEscrowV2.JobStatus.Expired) {
                totalResolved++;
            }
        }
        uint256 positives;
        for (uint256 i = 0; i < h.actorCount(); i++) {
            positives += h.reputation().getStats(h.actors(i)).positives;
        }
        // each approval: +1 provider; each completion: +1 client; each resolve: exactly one +1
        assertLe(positives, 2 * totalApproved + totalResolved, "reputation minted without work");
    }

    /// @dev Deterministic drive of the handler: proves the random surface reaches every terminal
    ///      state, so the invariants above are not vacuously true.
    function test_handlerReachesAllStates() public {
        uint256 seed = 7;
        for (uint256 i = 0; i < 3000; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 r = seed % 14;
            if (r < 3) h.createJob(seed, uint8(1 + ((seed >> 200) % 3)), uint32(seed >> 100));
            else if (r < 5) h.accept(seed, seed >> 16);
            else if (r == 5) h.submit(seed, uint8((seed >> 8) % 3), seed >> 16);
            else if (r == 6) h.approve(seed, uint8((seed >> 8) % 3), seed >> 16);
            else if (r == 7) h.claim(seed, uint8((seed >> 8) % 3), seed >> 16);
            else if (r == 8) h.reject(seed, uint8((seed >> 8) % 3), seed >> 16);
            else if (r == 9) h.cancel(seed, seed >> 16);
            else if (r == 10) h.dispute(seed, seed >> 16);
            else if (r == 11) h.resolve(seed, uint16(seed >> 8), seed >> 16);
            else if (r == 12) h.settleExpired(seed);
            else h.warp(uint32(seed >> 40));
            if (i % 50 == 0) h.withdrawClaimable(seed);
            if (i % 37 == 0) h.killSwitchOps(seed);
            if (i % 41 == 0) h.ownerOps(seed);
        }
        uint256 n = h.escrow().jobCount();
        uint256[6] memory byStatus;
        uint256 approved;
        for (uint256 i = 0; i < n; i++) {
            IAgentEscrowV2.Job memory j = h.escrow().getJob(i);
            byStatus[uint8(j.status)]++;
            approved += j.approvedCount;
        }
        assertGt(n, 50, "too few jobs");
        assertGt(approved, 10, "no approvals");
        assertGt(byStatus[uint8(IAgentEscrowV2.JobStatus.Completed)], 0, "no completed");
        assertGt(byStatus[uint8(IAgentEscrowV2.JobStatus.Cancelled)], 0, "no cancelled");
        assertGt(byStatus[uint8(IAgentEscrowV2.JobStatus.Resolved)], 0, "no resolved");
        assertGt(byStatus[uint8(IAgentEscrowV2.JobStatus.Expired)], 0, "no expired");
        assertGt(h.ghostPaidOut(), 0, "nothing paid out");
        invariant_solvency();
        invariant_conservation();
        invariant_jobAccounting();
    }
}
