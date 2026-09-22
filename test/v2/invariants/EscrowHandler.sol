// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {AgentAccess} from "../../../src/v2/AgentAccess.sol";
import {AgentEscrowV2} from "../../../src/v2/AgentEscrowV2.sol";
import {AgentReputationV2} from "../../../src/v2/AgentReputationV2.sol";
import {AgentAuditLogV2} from "../../../src/v2/AgentAuditLogV2.sol";
import {AgentKillSwitchV2} from "../../../src/v2/AgentKillSwitchV2.sol";
import {FeeRouter} from "../../../src/v2/FeeRouter.sol";
import {IAgentAccess} from "../../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentEscrowV2} from "../../../src/v2/interfaces/IAgentEscrowV2.sol";

/// @notice Stateful-fuzz handler: random actors drive every escrow entrypoint with valid and
///         invalid inputs, across time, with the real module contracts wired and the fee switch on.
///         Ghost variables track what the protocol owes so the invariant suite can check solvency.
contract EscrowHandler is Test {
    ERC20Mock public usdc;
    AgentAccess public access;
    AgentEscrowV2 public escrow;
    AgentReputationV2 public reputation;
    AgentAuditLogV2 public auditLog;
    AgentKillSwitchV2 public killSwitch;
    FeeRouter public feeRouter;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public stakingPool = makeAddr("stakingPool");
    address public stranger = makeAddr("stranger");
    address public anyone = makeAddr("anyone");
    address[] public actors;
    address[] public operators; // operators[i] is an operator for actors[i]

    // ghost accounting
    uint256 public ghostDeposited; // Σ total of all jobs created
    uint256 public ghostPaidOut; // Σ USDC that actually left the escrow to any party (transfer success)
    uint256 public ghostFeeRouted; // Σ fees successfully sent to router
    uint256 public calls;
    mapping(bytes32 => uint256) public callCount;

    constructor() {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        access = new AgentAccess();
        reputation = new AgentReputationV2(owner);
        auditLog = new AgentAuditLogV2(IAgentAccess(address(access)), owner);
        killSwitch = new AgentKillSwitchV2(owner);
        feeRouter = new FeeRouter(IERC20(address(usdc)), owner, treasury, stakingPool, address(0), 6000, 4000);
        escrow = new AgentEscrowV2(IAgentAccess(address(access)), IERC20(address(usdc)), owner);

        vm.startPrank(owner);
        reputation.authorizeProtocol(address(escrow));
        auditLog.authorizeProtocol(address(escrow));
        killSwitch.authorizeProtocol(address(escrow));
        feeRouter.authorizeProtocol(address(escrow));
        escrow.setModules(address(reputation), address(auditLog), address(killSwitch), address(feeRouter));
        escrow.setFeeBps(250);
        vm.stopPrank();

        for (uint256 i = 0; i < 6; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            address op = makeAddr(string.concat("op", vm.toString(i)));
            actors.push(a);
            operators.push(op);
            usdc.mint(a, 1_000_000_000_000);
            vm.prank(a);
            usdc.approve(address(escrow), type(uint256).max);
            vm.prank(a);
            access.authorizeOperator(op, type(uint48).max);
        }
        // Two actors opt into a kill switch so consume() paths are exercised.
        vm.prank(actors[0]);
        killSwitch.register(uint128(5_000_000_000), 50, 1 days);
        vm.prank(actors[1]);
        killSwitch.register(uint128(100_000_000), 3, 2 hours);
    }

    // ─── helpers ────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _caller(uint256 seed, address principal) internal view returns (address) {
        // 50%: principal itself, 40%: its operator, 10%: a stranger
        uint256 r = seed % 10;
        if (r < 5) return principal;
        if (r < 9) {
            for (uint256 i = 0; i < actors.length; i++) {
                if (actors[i] == principal) return operators[i];
            }
        }
        return stranger;
    }

    function _count(string memory k) internal {
        calls++;
        callCount[keccak256(bytes(k))]++;
    }

    function _try(address who, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(escrow).call(data);
    }

    function _escrowBal() internal view returns (uint256) {
        return usdc.balanceOf(address(escrow));
    }

    // ─── actions ────────────────────────────────────────────────────────

    function createJob(uint256 seed, uint8 n, uint32 durSeed) external {
        _count("createJob");
        IAgentEscrowV2.CreateParams memory p = _params(seed, uint8(bound(n, 0, 22)), durSeed);
        uint256 before = _escrowBal();
        bool ok = _try(_caller(seed >> 8, p.client), abi.encodeCall(escrow.createJob, (p)));
        if (ok) ghostDeposited += _escrowBal() - before;
    }

    function _params(
        uint256 seed,
        uint8 n,
        uint32 durSeed
    )
        internal
        view
        returns (IAgentEscrowV2.CreateParams memory p)
    {
        p.client = _actor(seed);
        p.provider = _actor(seed >> 16);
        p.arbiter = (seed >> 32) % 3 == 0 ? address(0) : _actor(seed >> 32);
        p.milestoneAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            p.milestoneAmounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 0, 400_000_000);
        }
        p.deadline = uint48(block.timestamp + bound(durSeed, 30 minutes, 400 days));
        p.termsHash = keccak256(abi.encode(seed));
    }

    function accept(uint256 jSeed, uint256 who) external {
        _count("accept");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        _try(_caller(who, j.provider), abi.encodeCall(escrow.acceptJob, (jobId)));
    }

    function submit(uint256 jSeed, uint8 idx, uint256 who) external {
        _count("submit");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        _try(
            _caller(who, j.provider),
            abi.encodeCall(escrow.submitMilestone, (jobId, idx, keccak256(abi.encode(jSeed, idx))))
        );
    }

    function approve(uint256 jSeed, uint8 idx, uint256 who) external {
        _count("approve");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        uint256 before = _escrowBal();
        bool ok = _try(_caller(who, j.client), abi.encodeCall(escrow.approveMilestone, (jobId, idx)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function claim(uint256 jSeed, uint8 idx, uint256 who) external {
        _count("claim");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        uint256 before = _escrowBal();
        bool ok = _try(_caller(who, j.provider), abi.encodeCall(escrow.claimApproval, (jobId, idx)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function reject(uint256 jSeed, uint8 idx, uint256 who) external {
        _count("reject");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        _try(_caller(who, j.client), abi.encodeCall(escrow.rejectMilestone, (jobId, idx, bytes32(jSeed))));
    }

    function cancel(uint256 jSeed, uint256 who) external {
        _count("cancel");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        uint256 before = _escrowBal();
        bool ok = _try(_caller(who, j.client), abi.encodeCall(escrow.cancelJob, (jobId)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function dispute(uint256 jSeed, uint256 who) external {
        _count("dispute");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        address principal = who % 2 == 0 ? j.client : j.provider;
        _try(_caller(who, principal), abi.encodeCall(escrow.dispute, (jobId, bytes32(jSeed))));
    }

    function resolve(uint256 jSeed, uint16 bps, uint256 who) external {
        _count("resolve");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        if (jobId >= escrow.jobCount()) return _tryInvalid(jobId);
        IAgentEscrowV2.Job memory j = escrow.getJob(jobId);
        bps = uint16(bound(bps, 0, 11_000));
        uint256 before = _escrowBal();
        bool ok = _try(_caller(who, j.arbiter), abi.encodeCall(escrow.resolve, (jobId, bps)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function settleExpired(uint256 jSeed) external {
        _count("settleExpired");
        uint256 jobId = _job(jSeed);
        if (jobId == type(uint256).max) return;
        uint256 before = _escrowBal();
        bool ok = _try(anyone, abi.encodeCall(escrow.settleExpired, (jobId)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function withdrawClaimable(uint256 who) external {
        _count("withdrawClaimable");
        address a = who % 7 == 0 ? owner : _actor(who);
        uint256 before = _escrowBal();
        bool ok = _try(a, abi.encodeCall(escrow.withdrawClaimable, (a, a)));
        if (ok) ghostPaidOut += before - _escrowBal();
    }

    function warp(uint32 by) external {
        _count("warp");
        vm.warp(block.timestamp + bound(by, 1, 20 days));
    }

    function killSwitchOps(uint256 seed) external {
        _count("killSwitch");
        address a = seed % 2 == 0 ? actors[0] : actors[1];
        uint256 r = seed % 5;
        vm.startPrank(a);
        if (r == 0) {
            (bool ok,) = address(killSwitch).call(abi.encodeCall(killSwitch.kill, (a)));
            ok;
        } else if (r == 1) {
            (bool ok,) = address(killSwitch).call(abi.encodeCall(killSwitch.resume, ()));
            ok;
        } else if (r == 2) {
            (bool ok,) = address(killSwitch).call(abi.encodeCall(killSwitch.pause, (a)));
            ok;
        } else if (r == 3) {
            (bool ok,) = address(killSwitch).call(abi.encodeCall(killSwitch.unpause, (a)));
            ok;
        } else {
            (bool ok,) = address(killSwitch).call(abi.encodeCall(killSwitch.resetSession, (a)));
            ok;
        }
        vm.stopPrank();
    }

    function ownerOps(uint256 seed) external {
        _count("ownerOps");
        uint256 r = seed % 6;
        vm.startPrank(owner);
        if (r == 0) {
            escrow.setFeeBps(seed % 501);
        } else if (r == 1) {
            (bool ok,) = address(reputation).call(abi.encodeCall(reputation.pause, ()));
            ok;
        } else if (r == 2) {
            (bool ok,) = address(reputation).call(abi.encodeCall(reputation.unpause, ()));
            ok;
        } else if (r == 3) {
            (bool ok,) = address(auditLog).call(abi.encodeCall(auditLog.pause, ()));
            ok;
        } else if (r == 4) {
            (bool ok,) = address(auditLog).call(abi.encodeCall(auditLog.unpause, ()));
            ok;
        } else {
            // simulate router misconfiguration then repair
            (bool ok,) = address(feeRouter).call(abi.encodeCall(feeRouter.revokeProtocol, (address(escrow))));
            if (!ok) feeRouter.authorizeProtocol(address(escrow));
        }
        vm.stopPrank();
    }

    /// @dev Exercise every entrypoint with a non-existent job id; all must revert JobNotFound.
    function _tryInvalid(uint256 jobId) internal {
        _try(anyone, abi.encodeCall(escrow.approveMilestone, (jobId, 0)));
        _try(anyone, abi.encodeCall(escrow.submitMilestone, (jobId, 0, bytes32(0))));
        _try(anyone, abi.encodeCall(escrow.dispute, (jobId, bytes32(0))));
        _try(anyone, abi.encodeCall(escrow.resolve, (jobId, 5000)));
        _try(anyone, abi.encodeCall(escrow.cancelJob, (jobId)));
    }

    // ─── job picker ─────────────────────────────────────────────────────

    function _job(uint256 seed) internal view returns (uint256) {
        uint256 n = escrow.jobCount();
        if (n == 0) return type(uint256).max;
        // bias toward recent jobs, occasionally pick an invalid id
        if (seed % 17 == 0) return n + (seed % 5);
        return seed % n;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
