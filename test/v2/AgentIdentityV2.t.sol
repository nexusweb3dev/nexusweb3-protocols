// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {AgentIdentityV2} from "../../src/v2/AgentIdentityV2.sol";
import {OperatorGated} from "../../src/v2/OperatorGated.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";
import {IAgentIdentityV2} from "../../src/v2/interfaces/IAgentIdentityV2.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract AgentIdentityV2Test is Test {
    AgentAccess access;
    MockERC721 erc8004;
    AgentIdentityV2 identity;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice"); // agent principal
    address bob = makeAddr("bob"); // agent principal
    address operator = makeAddr("operator"); // operator for alice
    address stranger = makeAddr("stranger");

    string constant NAME = "alice-agent";
    string constant URI = "ipfs://alice";
    uint8 constant AGENT_TYPE = 3;
    uint48 constant ONE_DAY = 1 days;

    function setUp() public {
        access = new AgentAccess();
        erc8004 = new MockERC721("ERC8004 Identity", "ID8004");
        identity = new AgentIdentityV2(IAgentAccess(address(access)), owner, address(erc8004));

        vm.warp(1_700_000_000);

        vm.prank(alice);
        access.authorizeOperator(operator, uint48(block.timestamp) + ONE_DAY);
    }

    function _register(address agent, string memory name) internal {
        vm.prank(agent);
        identity.register(agent, name, URI, AGENT_TYPE);
    }

    function _registerAlice() internal {
        _register(alice, NAME);
    }

    function _longString(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(identity.access()), address(access));
        assertEq(identity.owner(), owner);
        assertEq(identity.erc8004Registry(), address(erc8004));
        assertEq(identity.agentCount(), 0);
        assertFalse(identity.paused());
    }

    function test_constructorAllowsZeroRegistry() public {
        AgentIdentityV2 bare = new AgentIdentityV2(IAgentAccess(address(access)), owner, address(0));
        assertEq(bare.erc8004Registry(), address(0));
    }

    function test_revert_constructorZeroAccess() public {
        vm.expectRevert(OperatorGated.ZeroAccess.selector);
        new AgentIdentityV2(IAgentAccess(address(0)), owner, address(erc8004));
    }

    // ─── Register ───────────────────────────────────────────────────────

    function test_register() public {
        _registerAlice();

        IAgentIdentityV2.AgentProfile memory p = identity.getAgent(alice);
        assertEq(p.name, NAME);
        assertEq(p.agentURI, URI);
        assertEq(p.agentType, AGENT_TYPE);
        assertEq(p.registeredAt, uint48(block.timestamp));
        assertEq(p.updatedAt, uint48(block.timestamp));
        assertTrue(p.active);
        assertTrue(identity.isRegistered(alice));
        assertTrue(identity.exists(alice));
        assertEq(identity.agentCount(), 1);
        assertEq(identity.getAgentByName(NAME), alice);
    }

    function test_register_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(identity));
        emit IAgentIdentityV2.AgentRegistered(alice, NAME, AGENT_TYPE, URI);
        _registerAlice();
    }

    function test_register_emptyURIAllowed() public {
        vm.prank(alice);
        identity.register(alice, NAME, "", 0);
        assertEq(identity.getAgent(alice).agentURI, "");
    }

    function test_register_boundaryLengths() public {
        vm.prank(alice);
        identity.register(alice, _longString(64), _longString(512), 10);
        assertTrue(identity.isRegistered(alice));
    }

    function test_register_multipleAgents() public {
        _registerAlice();
        _register(bob, "bob-agent");
        assertEq(identity.agentCount(), 2);
        assertEq(identity.getAgentByName("bob-agent"), bob);
    }

    function test_revert_registerEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(IAgentIdentityV2.EmptyName.selector);
        identity.register(alice, "", URI, AGENT_TYPE);
    }

    function test_revert_registerNameTooLong() public {
        vm.prank(alice);
        vm.expectRevert(IAgentIdentityV2.NameTooLong.selector);
        identity.register(alice, _longString(65), URI, AGENT_TYPE);
    }

    function test_revert_registerURITooLong() public {
        vm.prank(alice);
        vm.expectRevert(IAgentIdentityV2.URITooLong.selector);
        identity.register(alice, NAME, _longString(513), AGENT_TYPE);
    }

    function test_revert_registerInvalidAgentType() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.InvalidAgentType.selector, uint8(11)));
        identity.register(alice, NAME, URI, 11);
    }

    function test_revert_registerTwice() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.AlreadyRegistered.selector, alice));
        identity.register(alice, "other-name", URI, AGENT_TYPE);
    }

    function test_revert_registerAfterDeactivate() public {
        _registerAlice();
        vm.prank(alice);
        identity.deactivate(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.AlreadyRegistered.selector, alice));
        identity.register(alice, "other-name", URI, AGENT_TYPE);
    }

    function test_revert_registerNameTaken() public {
        _registerAlice();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NameTaken.selector, keccak256(abi.encode(NAME))));
        identity.register(bob, NAME, URI, AGENT_TYPE);
    }

    function test_revert_registerByStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, alice, stranger));
        identity.register(alice, NAME, URI, AGENT_TYPE);
    }

    // ─── Operator path ──────────────────────────────────────────────────

    function test_operatorCanRegisterForPrincipal() public {
        vm.prank(operator);
        identity.register(alice, NAME, URI, AGENT_TYPE);
        assertTrue(identity.isRegistered(alice));
        assertEq(identity.getAgentByName(NAME), alice);
    }

    function test_operatorCanSetAgentURI() public {
        _registerAlice();
        vm.prank(operator);
        identity.setAgentURI(alice, "ipfs://new");
        assertEq(identity.getAgent(alice).agentURI, "ipfs://new");
    }

    function test_revert_expiredOperator() public {
        vm.warp(block.timestamp + ONE_DAY + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, alice, operator));
        identity.register(alice, NAME, URI, AGENT_TYPE);
    }

    function test_revert_revokedOperator() public {
        vm.prank(alice);
        access.revokeOperator(operator);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, alice, operator));
        identity.register(alice, NAME, URI, AGENT_TYPE);
    }

    function test_revert_operatorOfOtherPrincipal() public {
        _register(bob, "bob-agent");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, bob, operator));
        identity.setAgentURI(bob, "ipfs://hijack");
    }

    // ─── setAgentURI / setAgentType ─────────────────────────────────────

    function test_setAgentURI() public {
        _registerAlice();
        vm.warp(block.timestamp + 100);

        vm.expectEmit(true, false, false, true, address(identity));
        emit IAgentIdentityV2.AgentURIUpdated(alice, "ipfs://v2");
        vm.prank(alice);
        identity.setAgentURI(alice, "ipfs://v2");

        IAgentIdentityV2.AgentProfile memory p = identity.getAgent(alice);
        assertEq(p.agentURI, "ipfs://v2");
        assertEq(p.updatedAt, uint48(block.timestamp));
    }

    function test_setAgentType() public {
        _registerAlice();
        vm.warp(block.timestamp + 100);

        vm.expectEmit(true, false, false, true, address(identity));
        emit IAgentIdentityV2.AgentTypeUpdated(alice, 7);
        vm.prank(alice);
        identity.setAgentType(alice, 7);

        IAgentIdentityV2.AgentProfile memory p = identity.getAgent(alice);
        assertEq(p.agentType, 7);
        assertEq(p.updatedAt, uint48(block.timestamp));
    }

    function test_setters_workWhileDeactivated() public {
        _registerAlice();
        vm.startPrank(alice);
        identity.deactivate(alice);
        identity.setAgentURI(alice, "ipfs://still-editable");
        identity.setAgentType(alice, 1);
        vm.stopPrank();
        assertEq(identity.getAgent(alice).agentURI, "ipfs://still-editable");
    }

    function test_revert_setAgentURINotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.setAgentURI(alice, URI);
    }

    function test_revert_setAgentURITooLong() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(IAgentIdentityV2.URITooLong.selector);
        identity.setAgentURI(alice, _longString(513));
    }

    function test_revert_setAgentTypeNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.setAgentType(alice, 1);
    }

    function test_revert_setAgentTypeInvalid() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.InvalidAgentType.selector, uint8(255)));
        identity.setAgentType(alice, 255);
    }

    // ─── Deactivate / reactivate ────────────────────────────────────────

    function test_deactivate() public {
        _registerAlice();

        vm.expectEmit(true, false, false, false, address(identity));
        emit IAgentIdentityV2.AgentDeactivated(alice);
        vm.prank(alice);
        identity.deactivate(alice);

        assertFalse(identity.isRegistered(alice));
        assertTrue(identity.exists(alice));
        assertEq(identity.agentCount(), 0);
    }

    function test_deactivate_keepsNameReserved() public {
        _registerAlice();
        vm.prank(alice);
        identity.deactivate(alice);

        assertEq(identity.getAgentByName(NAME), alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NameTaken.selector, keccak256(abi.encode(NAME))));
        identity.register(bob, NAME, URI, AGENT_TYPE);
    }

    function test_reactivate() public {
        _registerAlice();
        vm.startPrank(alice);
        identity.deactivate(alice);

        vm.expectEmit(true, false, false, false, address(identity));
        emit IAgentIdentityV2.AgentReactivated(alice);
        identity.reactivate(alice);
        vm.stopPrank();

        assertTrue(identity.isRegistered(alice));
        assertEq(identity.agentCount(), 1);
        assertEq(identity.getAgent(alice).name, NAME);
        assertEq(identity.getAgentByName(NAME), alice);
    }

    function test_revert_deactivateNeverRegistered() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.deactivate(alice);
    }

    function test_revert_deactivateTwice() public {
        _registerAlice();
        vm.startPrank(alice);
        identity.deactivate(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.deactivate(alice);
        vm.stopPrank();
    }

    function test_revert_reactivateNeverRegistered() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.reactivate(alice);
    }

    function test_revert_reactivateWhenActive() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.AlreadyActive.selector, alice));
        identity.reactivate(alice);
    }

    // ─── ERC-8004 linking ───────────────────────────────────────────────

    function test_linkERC8004() public {
        _registerAlice();
        erc8004.mint(alice, 42);

        vm.expectEmit(true, true, false, false, address(identity));
        emit IAgentIdentityV2.ERC8004Linked(alice, 42);
        vm.prank(alice);
        identity.linkERC8004(alice, 42);

        assertEq(identity.erc8004IdOf(alice), 42);
        assertEq(identity.agentOfERC8004(42), alice);
    }

    function test_linkERC8004_byOperator() public {
        _registerAlice();
        erc8004.mint(alice, 7);
        vm.prank(operator);
        identity.linkERC8004(alice, 7);
        assertEq(identity.erc8004IdOf(alice), 7);
    }

    function test_linkERC8004_whileDeactivated() public {
        _registerAlice();
        erc8004.mint(alice, 7);
        vm.startPrank(alice);
        identity.deactivate(alice);
        identity.linkERC8004(alice, 7);
        vm.stopPrank();
        assertEq(identity.erc8004IdOf(alice), 7);
    }

    function test_linkERC8004_relinkUnlinksPrevious() public {
        _registerAlice();
        erc8004.mint(alice, 1);
        erc8004.mint(alice, 2);

        vm.prank(alice);
        identity.linkERC8004(alice, 1);

        vm.expectEmit(true, true, false, false, address(identity));
        emit IAgentIdentityV2.ERC8004Unlinked(alice, 1);
        vm.expectEmit(true, true, false, false, address(identity));
        emit IAgentIdentityV2.ERC8004Linked(alice, 2);
        vm.prank(alice);
        identity.linkERC8004(alice, 2);

        assertEq(identity.erc8004IdOf(alice), 2);
        assertEq(identity.agentOfERC8004(1), address(0));
        assertEq(identity.agentOfERC8004(2), alice);
    }

    function test_linkERC8004_sameIdIsIdempotent() public {
        _registerAlice();
        erc8004.mint(alice, 5);
        vm.startPrank(alice);
        identity.linkERC8004(alice, 5);
        identity.linkERC8004(alice, 5);
        vm.stopPrank();
        assertEq(identity.erc8004IdOf(alice), 5);
        assertEq(identity.agentOfERC8004(5), alice);
    }

    function test_unlinkERC8004() public {
        _registerAlice();
        erc8004.mint(alice, 9);
        vm.startPrank(alice);
        identity.linkERC8004(alice, 9);

        vm.expectEmit(true, true, false, false, address(identity));
        emit IAgentIdentityV2.ERC8004Unlinked(alice, 9);
        identity.unlinkERC8004(alice);
        vm.stopPrank();

        assertEq(identity.erc8004IdOf(alice), 0);
        assertEq(identity.agentOfERC8004(9), address(0));
    }

    function test_revert_linkERC8004NotConfigured() public {
        AgentIdentityV2 bare = new AgentIdentityV2(IAgentAccess(address(access)), owner, address(0));
        vm.startPrank(alice);
        bare.register(alice, NAME, URI, AGENT_TYPE);
        vm.expectRevert(IAgentIdentityV2.ERC8004NotConfigured.selector);
        bare.linkERC8004(alice, 1);
        vm.stopPrank();
    }

    function test_revert_linkERC8004NotRegistered() public {
        erc8004.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotRegistered.selector, alice));
        identity.linkERC8004(alice, 1);
    }

    function test_revert_linkERC8004NotOwner() public {
        _registerAlice();
        erc8004.mint(bob, 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotERC8004Owner.selector, uint256(3), bob));
        identity.linkERC8004(alice, 3);
    }

    function test_revert_linkERC8004NonexistentToken() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99)));
        identity.linkERC8004(alice, 99);
    }

    function test_linkERC8004_staleLinkOfFormerOwnerIsCleared() public {
        _registerAlice();
        _register(bob, "bob-agent");
        erc8004.mint(bob, 4);

        vm.prank(bob);
        identity.linkERC8004(bob, 4);

        // Token moves to alice; bob never unlinks. Alice (the real owner) can still link.
        vm.prank(bob);
        erc8004.transferFrom(bob, alice, 4);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit IAgentIdentityV2.ERC8004Unlinked(bob, 4);
        vm.expectEmit(true, true, false, false);
        emit IAgentIdentityV2.ERC8004Linked(alice, 4);
        identity.linkERC8004(alice, 4);

        assertEq(identity.erc8004IdOf(alice), 4);
        assertEq(identity.erc8004IdOf(bob), 0);
        assertEq(identity.agentOfERC8004(4), alice);
    }

    function test_revert_linkERC8004_currentOwnerStillLinked() public {
        _registerAlice();
        _register(bob, "bob-agent");
        erc8004.mint(bob, 4);
        vm.prank(bob);
        identity.linkERC8004(bob, 4);
        // Alice does not own the token: ownership check fires before any stale-link logic.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotERC8004Owner.selector, uint256(4), bob));
        identity.linkERC8004(alice, 4);
    }

    function test_revert_unlinkERC8004NotLinked() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.NotLinked.selector, alice));
        identity.unlinkERC8004(alice);
    }

    // ─── Owner functions ────────────────────────────────────────────────

    function test_setERC8004Registry() public {
        MockERC721 next = new MockERC721("Next", "NXT");

        vm.expectEmit(true, true, false, false, address(identity));
        emit IAgentIdentityV2.ERC8004RegistryUpdated(address(erc8004), address(next));
        vm.prank(owner);
        identity.setERC8004Registry(address(next));

        assertEq(identity.erc8004Registry(), address(next));
    }

    function test_setERC8004RegistryToZeroDisablesLinking() public {
        _registerAlice();
        erc8004.mint(alice, 1);

        vm.prank(owner);
        identity.setERC8004Registry(address(0));

        vm.prank(alice);
        vm.expectRevert(IAgentIdentityV2.ERC8004NotConfigured.selector);
        identity.linkERC8004(alice, 1);
    }

    function test_revert_setERC8004RegistryNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        identity.setERC8004Registry(address(0));
    }

    function test_revert_pauseNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        identity.pause();
    }

    function test_unpauseRestoresWrites() public {
        vm.prank(owner);
        identity.pause();
        vm.prank(owner);
        identity.unpause();

        _registerAlice();
        assertTrue(identity.isRegistered(alice));
    }

    // ─── Pause behavior ─────────────────────────────────────────────────

    function test_revert_registerWhenPaused() public {
        vm.prank(owner);
        identity.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        identity.register(alice, NAME, URI, AGENT_TYPE);
    }

    function test_revert_setAgentURIWhenPaused() public {
        _registerAlice();
        vm.prank(owner);
        identity.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        identity.setAgentURI(alice, URI);
    }

    function test_revert_setAgentTypeWhenPaused() public {
        _registerAlice();
        vm.prank(owner);
        identity.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        identity.setAgentType(alice, 1);
    }

    function test_revert_reactivateWhenPaused() public {
        _registerAlice();
        vm.prank(alice);
        identity.deactivate(alice);
        vm.prank(owner);
        identity.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        identity.reactivate(alice);
    }

    function test_revert_linkERC8004WhenPaused() public {
        _registerAlice();
        erc8004.mint(alice, 1);
        vm.prank(owner);
        identity.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        identity.linkERC8004(alice, 1);
    }

    function test_deactivateWorksWhilePaused() public {
        _registerAlice();
        vm.prank(owner);
        identity.pause();

        vm.prank(alice);
        identity.deactivate(alice);
        assertFalse(identity.isRegistered(alice));
    }

    function test_unlinkERC8004WorksWhilePaused() public {
        _registerAlice();
        erc8004.mint(alice, 1);
        vm.prank(alice);
        identity.linkERC8004(alice, 1);

        vm.prank(owner);
        identity.pause();

        vm.prank(alice);
        identity.unlinkERC8004(alice);
        assertEq(identity.erc8004IdOf(alice), 0);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function test_viewsOnUnknownAgent() public view {
        assertFalse(identity.isRegistered(stranger));
        assertFalse(identity.exists(stranger));
        assertEq(identity.erc8004IdOf(stranger), 0);
        assertEq(identity.agentOfERC8004(12_345), address(0));
        assertEq(identity.getAgentByName("nobody"), address(0));
        assertEq(identity.getAgent(stranger).registeredAt, 0);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_registerNameLength(uint8 len) public {
        string memory name = _longString(len);

        if (len == 0) {
            vm.prank(alice);
            vm.expectRevert(IAgentIdentityV2.EmptyName.selector);
            identity.register(alice, name, URI, AGENT_TYPE);
            return;
        }
        if (len > 64) {
            vm.prank(alice);
            vm.expectRevert(IAgentIdentityV2.NameTooLong.selector);
            identity.register(alice, name, URI, AGENT_TYPE);
            return;
        }

        vm.prank(alice);
        identity.register(alice, name, URI, AGENT_TYPE);
        assertEq(identity.getAgentByName(name), alice);
    }

    function testFuzz_registerAgentType(uint8 agentType) public {
        if (agentType > 10) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IAgentIdentityV2.InvalidAgentType.selector, agentType));
            identity.register(alice, NAME, URI, agentType);
            return;
        }

        vm.prank(alice);
        identity.register(alice, NAME, URI, agentType);
        assertEq(identity.getAgent(alice).agentType, agentType);
    }

    function testFuzz_uriLength(uint16 len) public {
        len = uint16(bound(len, 0, 1024));
        string memory uri = _longString(len);

        vm.prank(alice);
        if (len > 512) {
            vm.expectRevert(IAgentIdentityV2.URITooLong.selector);
            identity.register(alice, NAME, uri, AGENT_TYPE);
            return;
        }
        identity.register(alice, NAME, uri, AGENT_TYPE);
        assertEq(bytes(identity.getAgent(alice).agentURI).length, len);
    }

    function testFuzz_operatorExpiryBoundary(uint48 skipTo) public {
        uint48 expiry = uint48(block.timestamp) + ONE_DAY;
        skipTo = uint48(bound(skipTo, uint48(block.timestamp), expiry + 10 days));
        vm.warp(skipTo);

        vm.prank(operator);
        if (skipTo >= expiry) {
            vm.expectRevert(abi.encodeWithSelector(OperatorGated.NotAgentOrOperator.selector, alice, operator));
            identity.register(alice, NAME, URI, AGENT_TYPE);
            return;
        }
        identity.register(alice, NAME, URI, AGENT_TYPE);
        assertTrue(identity.isRegistered(alice));
    }

    function testFuzz_agentCountTracksActive(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        for (uint256 i; i < n; ++i) {
            address agent = address(uint160(0x1000 + i));
            vm.prank(agent);
            identity.register(agent, string(abi.encodePacked("agent-", vm.toString(i))), URI, 0);
        }
        assertEq(identity.agentCount(), n);

        for (uint256 i; i < n; ++i) {
            address agent = address(uint160(0x1000 + i));
            vm.prank(agent);
            identity.deactivate(agent);
        }
        assertEq(identity.agentCount(), 0);
    }
}
