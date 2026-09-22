// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AgentAccess} from "../../../src/v2/AgentAccess.sol";
import {AgentIdentityV2} from "../../../src/v2/AgentIdentityV2.sol";
import {AgentReputationV2} from "../../../src/v2/AgentReputationV2.sol";
import {AgentAuditLogV2} from "../../../src/v2/AgentAuditLogV2.sol";
import {IAgentAccess} from "../../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentIdentityV2} from "../../../src/v2/interfaces/IAgentIdentityV2.sol";
import {IAgentReputationV2} from "../../../src/v2/interfaces/IAgentReputationV2.sol";
import {IAgentAuditLogV2} from "../../../src/v2/interfaces/IAgentAuditLogV2.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// @title AuditDataTest
/// @notice Pre-deployment audit PoCs for AgentIdentityV2, AgentReputationV2, AgentAuditLogV2 and the
///         deploy-script ownership/wiring ordering, migrated to the fixed contracts. Tests marked
///         `FIXED: <id>` keep the original scenario and assert the guarantee the fix provides;
///         everything else documents behaviour that is still accepted.
///         Run: forge test --match-path test/v2/audit/AuditData.t.sol -vv
contract AuditDataTest is Test {
    AgentAccess access;
    MockERC721 registry;
    MockERC721 registry2;
    AgentIdentityV2 identity;
    AgentReputationV2 rep;
    AgentAuditLogV2 auditLog;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address operator = makeAddr("operator");
    address protocol = makeAddr("protocol");

    string constant URI = "ipfs://x";
    uint8 constant AGENT_TYPE = 1;
    uint256 constant UNIT = 100e6;
    /// @dev Storage slot of `AgentReputationV2._stats` (forge inspect … storage-layout).
    uint256 constant REP_STATS_SLOT = 2;

    function setUp() public {
        vm.warp(1_700_000_000);
        access = new AgentAccess();
        registry = new MockERC721("ERC8004", "ID");
        registry2 = new MockERC721("ERC8004-v2", "ID2");
        identity = new AgentIdentityV2(IAgentAccess(address(access)), owner, address(registry));
        rep = new AgentReputationV2(owner);
        auditLog = new AgentAuditLogV2(IAgentAccess(address(access)), owner);

        vm.prank(owner);
        rep.authorizeProtocol(protocol);
        vm.prank(owner);
        auditLog.authorizeProtocol(protocol);
    }

    function _register(address agent, string memory name) internal {
        vm.prank(agent);
        identity.register(agent, name, URI, AGENT_TYPE);
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentIdentityV2 — ERC-8004 link mapping integrity
    // ══════════════════════════════════════════════════════════════════════

    /// FIXED: ID-01
    /// @notice The fix guarantees agentId 0 is rejected at link time, so the "not linked" sentinel of
    ///         `erc8004IdOf` can never collide with a real link and become unremovable.
    ///         Reachable on the configured mainnet registry: agentId 0 EXISTS on Base
    ///         0x8004A169FB4a3325136EB29fA0ceB6D2e539a432 and is owned by
    ///         0xa1DaEe3EB47f05f857aCA817523F9ff11d95bD71 (verified via eth_call, Sep 22 2026).
    function test_linkTokenIdZeroIsRejected() public {
        _register(alice, "alice");
        registry.mint(alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.InvalidERC8004Id.selector));
        identity.linkERC8004(alice, 0);

        assertEq(identity.agentOfERC8004(0), address(0), "id 0 is never linkable");
        assertEq(identity.erc8004IdOf(alice), 0, "and the forward map still reads as unlinked");

        // Any non-zero id links normally, and the invariant holds in both directions.
        registry.mint(alice, 1);
        vm.prank(alice);
        identity.linkERC8004(alice, 1);
        assertEq(identity.agentOfERC8004(1), alice);
        assertEq(identity.erc8004IdOf(alice), 1);

        // The exit path works too, which it never did for the id-0 entry.
        vm.prank(alice);
        identity.unlinkERC8004(alice);
        assertEq(identity.erc8004IdOf(alice), 0);
        assertEq(identity.agentOfERC8004(1), address(0));
    }

    /// FIXED: ID-02
    /// @notice The fix guarantees a re-link clears its own stale reverse entry, so a later linker of
    ///         the abandoned id cannot take the stale-clear branch and destroy an unrelated,
    ///         still-valid link belonging to another agent.
    function test_relinkDoesNotDestroyAnotherAgentsLink() public {
        _register(alice, "alice");
        _register(bob, "bob");
        registry.mint(alice, 1);
        registry.mint(alice, 5);

        vm.startPrank(alice);
        identity.linkERC8004(alice, 1);
        identity.linkERC8004(alice, 5); // clears the reverse entry for id 1
        registry.transferFrom(alice, bob, 1); // alice keeps token 5
        vm.stopPrank();

        assertEq(identity.agentOfERC8004(1), address(0), "abandoned id left no dangling reverse entry");
        assertEq(identity.erc8004IdOf(alice), 5, "alice linked to 5 before bob acts");

        vm.prank(bob);
        identity.linkERC8004(bob, 1);

        assertEq(identity.erc8004IdOf(alice), 5, "alice's link to token 5 survives");
        assertEq(identity.agentOfERC8004(5), alice, "and the reverse map agrees");
        assertEq(identity.agentOfERC8004(1), bob, "bob holds the id he actually owns");
    }

    /// @notice Invariant holds for every sequence of link/unlink/transfer as long as agentId != 0.
    ///         This is the control experiment for ID-01/ID-02: the only broken id was 0.
    function testFuzz_linkInvariantHoldsForNonZeroIds(uint8 idSeed, uint8 steps) public {
        uint256 id1 = uint256(idSeed) + 1;
        uint256 id2 = id1 + 1000;
        _register(alice, "alice");
        _register(bob, "bob");
        registry.mint(alice, id1);
        registry.mint(bob, id2);

        uint256 n = uint256(steps) % 12;
        for (uint256 i; i < n; ++i) {
            uint256 pick = uint256(keccak256(abi.encode(idSeed, steps, i))) % 5;
            if (pick == 0) {
                vm.prank(alice);
                try identity.linkERC8004(alice, id1) {} catch {}
            } else if (pick == 1) {
                vm.prank(bob);
                try identity.linkERC8004(bob, id2) {} catch {}
            } else if (pick == 2) {
                vm.prank(alice);
                try identity.unlinkERC8004(alice) {} catch {}
            } else if (pick == 3) {
                vm.prank(bob);
                try identity.unlinkERC8004(bob) {} catch {}
            } else {
                address holder = registry.ownerOf(id1);
                address to = holder == alice ? bob : alice;
                vm.prank(holder);
                registry.transferFrom(holder, to, id1);
                address newHolder = registry.ownerOf(id1);
                vm.prank(newHolder);
                try identity.linkERC8004(newHolder, id1) {} catch {}
            }
            _assertLinkInvariant(id1);
            _assertLinkInvariant(id2);
        }
    }

    function _assertLinkInvariant(uint256 id) internal view {
        address a = identity.agentOfERC8004(id);
        if (a != address(0)) {
            assertEq(identity.erc8004IdOf(a), id, "reverse/forward map disagree");
        }
    }

    /// @notice Documents accepted risk: a link is NOT cleared when the ERC-721 moves. Every reader of
    ///         `agentOfERC8004` / `erc8004IdOf` sees a former owner as the linked agent until the new
    ///         owner happens to call `linkERC8004`. Consumers must re-check `ownerOf` themselves.
    function test_staleLinkSurvivesTransfer_readersSeeFormerOwner() public {
        _register(alice, "alice");
        registry.mint(alice, 7);
        vm.prank(alice);
        identity.linkERC8004(alice, 7);

        vm.prank(alice);
        registry.transferFrom(alice, carol, 7); // carol never links

        assertEq(registry.ownerOf(7), carol, "carol owns the token");
        assertEq(identity.agentOfERC8004(7), alice, "identity still reports alice");
        assertEq(identity.erc8004IdOf(alice), 7, "alice still reports a link she cannot back");
    }

    /// FIXED: ID-03
    /// @notice The fix guarantees a registry swap invalidates every existing link through the epoch
    ///         counter, because those links were validated against a registry that is no longer
    ///         authoritative. Agents re-link (or unlink) under the new registry.
    function test_registryChangeInvalidatesExistingLinks() public {
        _register(alice, "alice");
        registry.mint(alice, 9);
        vm.prank(alice);
        identity.linkERC8004(alice, 9);
        assertEq(identity.erc8004IdOf(alice), 9, "linked under the old registry");

        uint32 epochBefore = identity.registryEpoch();
        vm.prank(owner);
        identity.setERC8004Registry(address(registry2));
        assertEq(identity.registryEpoch(), epochBefore + 1, "the swap bumps the epoch");

        assertEq(identity.erc8004IdOf(alice), 0, "an unverified link no longer reads as valid");
        assertEq(identity.agentOfERC8004(9), address(0), "and neither does the reverse direction");

        // Re-validating under the new registry restores the link.
        registry2.mint(alice, 9);
        vm.prank(alice);
        identity.linkERC8004(alice, 9);
        assertEq(identity.erc8004IdOf(alice), 9, "re-verified against registry2");
        assertEq(identity.agentOfERC8004(9), alice);
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentIdentityV2 — name namespace
    // ══════════════════════════════════════════════════════════════════════

    /// FIXED: ID-04
    /// @notice The fix guarantees names are restricted to `[a-z0-9-_.]`, so a Cyrillic homoglyph, a
    ///         case variant, a leading space and a NUL-padded name can no longer register alongside
    ///         a genuine handle and shadow it in a UI.
    function test_nameNamespaceRejectsHomoglyphsCaseAndControlBytes() public {
        _register(alice, "atlas");

        _expectInvalidName(bob, unicode"аtlas"); // U+0430 CYRILLIC SMALL LETTER A
        _expectInvalidName(carol, "Atlas");
        _expectInvalidName(makeAddr("d"), " atlas");
        _expectInvalidName(makeAddr("e"), "atlas\x00");

        assertEq(identity.getAgentByName("atlas"), alice);
        assertEq(identity.agentCount(), 1, "only the genuine handle exists");

        // The permitted set still covers realistic handles.
        _register(bob, "atlas-2.bot_v1");
        assertEq(identity.getAgentByName("atlas-2.bot_v1"), bob);
        assertEq(identity.agentCount(), 2);
    }

    function _expectInvalidName(address agent, string memory name) internal {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.InvalidName.selector));
        identity.register(agent, name, URI, AGENT_TYPE);
    }

    /// @notice A name is bound to the principal forever. Deactivating does not release it, there is no
    ///         rename and no owner override, so a lost key burns the handle permanently.
    function test_nameIsUnrecoverableAfterDeactivate() public {
        _register(alice, "atlas");
        vm.prank(alice);
        identity.deactivate(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NameTaken.selector, keccak256(abi.encode("atlas"))));
        identity.register(bob, "atlas", URI, AGENT_TYPE);

        // Not even the original principal can re-register or rename.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.AlreadyRegistered.selector, alice));
        identity.register(alice, "atlas-2", URI, AGENT_TYPE);
        assertEq(identity.getAgentByName("atlas"), alice, "name stays reserved for alice");
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentReputationV2 — score math and Sybil economics
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Score arithmetic cannot overflow even at saturated counters. Writing all ones into the
    ///         `_stats` slot sets positives = negatives = uint64.max and volumeUsdc = uint128.max.
    function test_scoreDoesNotOverflowAtSaturatedCounters() public {
        bytes32 slot = keccak256(abi.encode(alice, REP_STATS_SLOT));
        vm.store(address(rep), slot, bytes32(type(uint256).max));

        IAgentReputationV2.Stats memory s = rep.getStats(alice);
        assertEq(s.positives, type(uint64).max);
        assertEq(s.negatives, type(uint64).max);
        assertEq(s.volumeUsdc, type(uint128).max);

        uint256 expected =
            100 + 10 * uint256(type(uint64).max) + uint256(type(uint128).max) / UNIT - 20 * uint256(type(uint64).max);
        assertEq(rep.getScore(alice), expected, "no overflow, no underflow");
        assertEq(uint8(rep.getTier(alice)), uint8(IAgentReputationV2.Tier.PLATINUM));
    }

    /// @notice Accepted at the module level: one recorded interaction still buys the top tier, because
    ///         `valueUsdc` is an unverified number supplied by the authorized protocol. The escrow
    ///         bounds this at its own boundary (MIN_REPUTATION_VALUE + MAX_REPUTATION_PER_PAIR), so
    ///         the guarantee lives with the writer, not with this contract.
    function test_singleInteractionReachesPlatinum() public {
        vm.prank(protocol);
        rep.recordInteraction(alice, true, 1, 90_000e6);

        assertEq(rep.getScore(alice), 100 + 10 + 900);
        assertEq(uint8(rep.getTier(alice)), uint8(IAgentReputationV2.Tier.PLATINUM), "1 tx -> PLATINUM");
        assertEq(rep.getStats(alice).positives, 1, "backed by a single interaction");
    }

    /// @notice A proven-bad agent and a brand-new address are the same tier. `getTier` alone can never
    ///         separate "no history" from "50 failed jobs".
    function test_tierCannotSeparateUnknownFromProvenBad() public {
        vm.startPrank(protocol);
        for (uint256 i; i < 50; ++i) {
            rep.recordInteraction(alice, false, 0, 0);
        }
        vm.stopPrank();

        assertEq(rep.getScore(alice), 0, "floored");
        assertEq(uint8(rep.getTier(alice)), uint8(IAgentReputationV2.Tier.BRONZE));
        assertEq(uint8(rep.getTier(bob)), uint8(IAgentReputationV2.Tier.BRONZE), "never-seen agent");
        assertEq(rep.getStats(bob).firstSeen, 0, "only firstSeen tells them apart");
    }

    /// @notice Revoking a compromised protocol does not undo anything it wrote. There is no owner
    ///         correction path, so a single buggy or compromised authorized protocol permanently
    ///         poisons reputation.
    function test_revocationDoesNotUndoPoisonedReputation() public {
        vm.prank(protocol);
        rep.recordInteraction(alice, true, 0, 500_000e6);
        uint256 poisoned = rep.getScore(alice);

        vm.prank(owner);
        rep.revokeProtocol(protocol);

        assertEq(rep.getScore(alice), poisoned, "score unchanged after revocation");
        assertEq(uint8(rep.getTier(alice)), uint8(IAgentReputationV2.Tier.PLATINUM));
    }

    /// @notice Emitted `valueUsdc` and stored `volumeUsdc` diverge once volume saturates, so an indexer
    ///         summing events will not match on-chain state.
    function test_eventValueDivergesFromStoredVolumeAtSaturation() public {
        bytes32 slot = keccak256(abi.encode(alice, REP_STATS_SLOT));
        vm.store(address(rep), slot, bytes32(uint256(type(uint128).max) << 128));
        assertEq(rep.getStats(alice).volumeUsdc, type(uint128).max);

        vm.prank(protocol);
        vm.expectEmit(true, true, false, true);
        emit IAgentReputationV2.InteractionRecorded(alice, protocol, true, 0, 1000e6);
        rep.recordInteraction(alice, true, 0, 1000e6);

        assertEq(rep.getStats(alice).volumeUsdc, type(uint128).max, "stored volume absorbed nothing");
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentAuditLogV2 — growth and authorship
    // ══════════════════════════════════════════════════════════════════════

    /// FIXED: AL-1
    /// @notice The fix guarantees `getAgentLogs` clips `limit` to MAX_PAGE_SIZE, so the cost of a read
    ///         is bounded by what the caller asked for rather than by how much history the agent has.
    function test_getAgentLogsIsCappedAtMaxPageSize() public {
        _fillLogs(alice, 1000);
        assertEq(auditLog.getLogCount(alice), 1000);

        uint256 cap = auditLog.MAX_PAGE_SIZE();
        uint256 g0 = gasleft();
        IAgentAuditLogV2.ActionLog[] memory page = auditLog.getAgentLogs(alice, 0, type(uint256).max);
        uint256 used = g0 - gasleft();

        assertEq(page.length, cap, "an unbounded request returns exactly one page");
        console.log("gas for getAgentLogs(agent, 0, type(uint256).max) over 1000 entries:", used);
        assertLt(used, 4_000_000, "a full page stays far inside an eth_call budget");

        // The whole history is still reachable by paging, and a short tail is not padded.
        IAgentAuditLogV2.ActionLog[] memory tail = auditLog.getAgentLogs(alice, 900, type(uint256).max);
        assertEq(tail.length, 100, "last partial page");
        assertEq(tail[99].agent, alice);
    }

    /// @notice An authorized protocol may append to ANY agent's log. A compromised protocol can both
    ///         forge history for an innocent agent and grief its readers by inflating the page size.
    function test_authorizedProtocolCanForgeAndInflateAnyAgentLog() public {
        assertEq(auditLog.getLogCount(bob), 0);

        vm.startPrank(protocol);
        for (uint256 i; i < 5; ++i) {
            auditLog.log(bob, keccak256("RUG_PULL"), keccak256(abi.encode("fabricated", i)), 1);
        }
        vm.stopPrank();

        assertEq(auditLog.getLogCount(bob), 5, "bob never consented to any of these");
        assertEq(auditLog.getLog(0).agent, bob);
        assertEq(auditLog.getLog(0).caller, protocol, "caller field is the only provenance signal");
    }

    /// @notice An operator writes history that outlives its own authorization. Revoking the operator
    ///         does not remove or flag entries it already wrote; the log is append-only by design.
    function test_revokedOperatorHistoryIsPermanent() public {
        vm.prank(alice);
        access.authorizeOperator(operator, uint48(block.timestamp + 1 days));

        vm.prank(operator);
        auditLog.log(alice, keccak256("PAYMENT"), keccak256("bad-data"), 42);

        vm.prank(alice);
        access.revokeOperator(operator);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentAuditLogV2.NotAuthorizedLogger.selector, alice, operator));
        auditLog.log(alice, keccak256("PAYMENT"), keccak256("more"), 1);

        assertEq(auditLog.getLogCount(alice), 1, "the entry written while authorized is permanent");
        assertEq(auditLog.getLog(0).caller, operator);
    }

    /// @notice Anyone may spam their own log for the cost of gas; storage grows forever and the only
    ///         defence is the owner pausing all logging for everybody.
    function test_selfSpamGrowsStorageUnboundedAndOnlyGlobalPauseStopsIt() public {
        _fillLogs(carol, 100);
        assertEq(auditLog.totalLogs(), 100);

        vm.prank(owner);
        auditLog.pause();

        // The global pause also blocks every honest agent.
        vm.prank(alice);
        vm.expectRevert();
        auditLog.log(alice, keccak256("PAYMENT"), keccak256("honest"), 1);
    }

    function _fillLogs(address agent, uint256 count) internal {
        vm.startPrank(agent);
        uint256 written;
        while (written < count) {
            uint256 batch = count - written < 50 ? count - written : 50;
            bytes32[] memory t = new bytes32[](batch);
            bytes32[] memory h = new bytes32[](batch);
            uint256[] memory v = new uint256[](batch);
            for (uint256 i; i < batch; ++i) {
                t[i] = keccak256(abi.encode("T", written + i));
                h[i] = keccak256(abi.encode("H", written + i));
                v[i] = written + i;
            }
            auditLog.logBatch(agent, t, h, v);
            written += batch;
        }
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    // Deploy scripts — ownership ordering
    // ══════════════════════════════════════════════════════════════════════

    /// @notice DeployCore's ordering still holds, with more slack than before: `transferOwnership` is
    ///         now only a proposal, so the deployer keeps admin until the intended owner accepts.
    ///         Wiring must precede `acceptOwnership`, not `transferOwnership`.
    function test_wiringMustPrecedeOwnershipAcceptance() public {
        AgentReputationV2 fresh = new AgentReputationV2(address(this)); // deployer-owned, as in _deploy
        fresh.authorizeProtocol(protocol); // _wire works
        assertTrue(fresh.isAuthorizedProtocol(protocol));

        fresh.transferOwnership(owner); // _transferOwnership: a proposal only
        assertEq(fresh.owner(), address(this), "still the deployer");
        assertEq(fresh.pendingOwner(), owner, "handover queued");
        fresh.authorizeProtocol(bob); // late wiring is still possible

        vm.prank(owner);
        fresh.acceptOwnership();
        assertEq(fresh.owner(), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.authorizeProtocol(carol);
    }

    /// FIXED: H-02
    /// @notice The fix guarantees every module handed over by the deploy script uses two-step
    ///         ownership, so `transferOwnership` alone never moves the admin role.
    function test_allModulesUseTwoStepOwnership() public {
        vm.startPrank(owner);
        identity.transferOwnership(alice);
        rep.transferOwnership(alice);
        auditLog.transferOwnership(alice);
        vm.stopPrank();

        assertEq(identity.owner(), owner, "identity owner unchanged");
        assertEq(rep.owner(), owner, "reputation owner unchanged");
        assertEq(auditLog.owner(), owner, "audit log owner unchanged");
        assertEq(identity.pendingOwner(), alice);
        assertEq(rep.pendingOwner(), alice);
        assertEq(auditLog.pendingOwner(), alice);

        // Only the named successor can complete the handover.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        identity.acceptOwnership();

        vm.startPrank(alice);
        identity.acceptOwnership();
        rep.acceptOwnership();
        auditLog.acceptOwnership();
        vm.stopPrank();

        assertEq(identity.owner(), alice);
        assertEq(rep.owner(), alice);
        assertEq(auditLog.owner(), alice);
    }

    /// FIXED: DEP-1
    /// @notice The fix guarantees a wrong `OWNER` env value cannot permanently brick admin: with
    ///         two-step ownership the deployer keeps pause, protocol authorization, setFeeBps and
    ///         setModules until the intended owner actively accepts, so the typo is correctable.
    function test_ownerTypoDoesNotBrickAdmin() public {
        address typo = address(uint160(uint256(keccak256("unowned-address"))));
        AgentReputationV2 fresh = new AgentReputationV2(address(this));
        fresh.transferOwnership(typo);

        assertEq(fresh.pendingOwner(), typo, "handover only queued");
        assertEq(fresh.owner(), address(this), "deployer keeps control");
        fresh.pause();
        fresh.unpause();
        fresh.authorizeProtocol(protocol);

        // Re-pointing the handover at the real owner is all it takes to recover.
        fresh.transferOwnership(owner);
        vm.prank(typo);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, typo));
        fresh.acceptOwnership();

        vm.prank(owner);
        fresh.acceptOwnership();
        assertEq(fresh.owner(), owner, "ownership lands with the intended owner");
    }
}
