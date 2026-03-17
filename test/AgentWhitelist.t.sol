// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentWhitelist} from "../src/AgentWhitelist.sol";
import {AgentReputation} from "../src/AgentReputation.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAgentWhitelist} from "../src/interfaces/IAgentWhitelist.sol";

contract AgentWhitelistTest is Test {
    AgentReputation rep;
    AgentRegistry reg;
    ERC20Mock usdc;
    AgentWhitelist whitelist;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant CREATE_FEE = 0.01 ether;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        rep = new AgentReputation(treasury, owner, 0);
        reg = new AgentRegistry(IERC20(address(usdc)), treasury, owner, 5_000_000, 1_000_000);

        whitelist = new AgentWhitelist(address(reg), address(rep), treasury, owner, CREATE_FEE);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // register alice on AgentRegistry
        usdc.mint(alice, 100_000_000);
        vm.prank(alice);
        usdc.approve(address(reg), type(uint256).max);
        vm.prank(alice);
        reg.registerAgent("alice-agent", "https://alice.test", 0);

        // give alice high reputation
        vm.prank(owner);
        rep.authorizeProtocol(address(this));
        for (uint i; i < 20; i++) {
            rep.recordInteraction(alice, true, 0); // score = 300
        }
    }

    function _createDefault() internal returns (uint256) {
        vm.prank(alice);
        return whitelist.createWhitelist{value: CREATE_FEE}("Test List", false, 0);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(whitelist.treasury(), treasury);
        assertEq(whitelist.owner(), owner);
        assertEq(whitelist.creationFee(), CREATE_FEE);
        assertEq(whitelist.whitelistCount(), 0);
    }

    function test_revert_constructorZeroRegistry() public {
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        new AgentWhitelist(address(0), address(rep), treasury, owner, CREATE_FEE);
    }

    function test_revert_constructorZeroReputation() public {
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        new AgentWhitelist(address(reg), address(0), treasury, owner, CREATE_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        new AgentWhitelist(address(reg), address(rep), address(0), owner, CREATE_FEE);
    }

    // ─── Create Whitelist ───────────────────────────────────────────────

    function test_createWhitelist() public {
        uint256 id = _createDefault();

        assertEq(id, 0);
        assertEq(whitelist.whitelistCount(), 1);

        IAgentWhitelist.Whitelist memory wl = whitelist.getWhitelist(id);
        assertEq(wl.listOwner, alice);
        assertEq(wl.agentCount, 0);
        assertFalse(wl.requireRegistered);
        assertEq(wl.minReputation, 0);
    }

    function test_createWithRequirements() public {
        vm.prank(alice);
        uint256 id = whitelist.createWhitelist{value: CREATE_FEE}("Strict", true, 200);

        IAgentWhitelist.Whitelist memory wl = whitelist.getWhitelist(id);
        assertTrue(wl.requireRegistered);
        assertEq(wl.minReputation, 200);
    }

    function test_createCollectsFee() public {
        _createDefault();
        assertEq(whitelist.accumulatedFees(), CREATE_FEE);
    }

    function test_revert_createEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(IAgentWhitelist.EmptyName.selector);
        whitelist.createWhitelist{value: CREATE_FEE}("", false, 0);
    }

    function test_revert_createInsufficientFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.InsufficientFee.selector, CREATE_FEE, 0));
        whitelist.createWhitelist("Test", false, 0);
    }

    function test_revert_createWhenPaused() public {
        vm.prank(owner);
        whitelist.pause();

        vm.prank(alice);
        vm.expectRevert();
        whitelist.createWhitelist{value: CREATE_FEE}("Paused", false, 0);
    }

    // ─── Add / Remove Agent ─────────────────────────────────────────────

    function test_addAgent() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        whitelist.addAgent(id, bob);

        assertTrue(whitelist.isManuallyWhitelisted(id, bob));

        IAgentWhitelist.Whitelist memory wl = whitelist.getWhitelist(id);
        assertEq(wl.agentCount, 1);
    }

    function test_removeAgent() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        whitelist.addAgent(id, bob);

        vm.prank(alice);
        whitelist.removeAgent(id, bob);

        assertFalse(whitelist.isManuallyWhitelisted(id, bob));
        assertEq(whitelist.getWhitelist(id).agentCount, 0);
    }

    function test_revert_addNotOwner() public {
        uint256 id = _createDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.NotWhitelistOwner.selector, id));
        whitelist.addAgent(id, charlie);
    }

    function test_revert_addZeroAddress() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        whitelist.addAgent(id, address(0));
    }

    function test_revert_addDuplicate() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        whitelist.addAgent(id, bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.AgentAlreadyWhitelisted.selector, id, bob));
        whitelist.addAgent(id, bob);
    }

    function test_revert_removeNotWhitelisted() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.AgentNotWhitelisted.selector, id, bob));
        whitelist.removeAgent(id, bob);
    }

    // ─── isWhitelisted (manual + auto) ──────────────────────────────────

    function test_manualWhitelisted() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        whitelist.addAgent(id, bob);

        assertTrue(whitelist.isWhitelisted(id, bob));
    }

    function test_autoQualifyByReputation() public {
        // create whitelist requiring 200+ reputation
        vm.prank(alice);
        uint256 id = whitelist.createWhitelist{value: CREATE_FEE}("Rep List", false, 200);

        // alice has score 300 (20 positives = 100 + 200)
        assertTrue(whitelist.isWhitelisted(id, alice));

        // bob has score 100 (default) — not enough
        assertFalse(whitelist.isWhitelisted(id, bob));
    }

    function test_autoQualifyByRegistration() public {
        vm.prank(alice);
        uint256 id = whitelist.createWhitelist{value: CREATE_FEE}("Reg List", true, 0);

        // alice is registered
        assertTrue(whitelist.isWhitelisted(id, alice));

        // bob is NOT registered
        assertFalse(whitelist.isWhitelisted(id, bob));
    }

    function test_autoQualifyBothRequirements() public {
        vm.prank(alice);
        uint256 id = whitelist.createWhitelist{value: CREATE_FEE}("Strict", true, 200);

        // alice: registered + 300 rep → passes
        assertTrue(whitelist.isWhitelisted(id, alice));

        // bob: not registered → fails
        assertFalse(whitelist.isWhitelisted(id, bob));
    }

    function test_notWhitelistedInvalidId() public view {
        assertFalse(whitelist.isWhitelisted(999, alice));
    }

    // ─── Ownership Transfer ─────────────────────────────────────────────

    function test_transferOwnership() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        whitelist.transferWhitelistOwnership(id, bob);

        vm.prank(bob);
        whitelist.acceptWhitelistOwnership(id);

        assertEq(whitelist.getWhitelist(id).listOwner, bob);
    }

    function test_revert_acceptNotPending() public {
        uint256 id = _createDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.NotPendingOwner.selector, id));
        whitelist.acceptWhitelistOwnership(id);
    }

    function test_revert_transferNotOwner() public {
        uint256 id = _createDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.NotWhitelistOwner.selector, id));
        whitelist.transferWhitelistOwnership(id, charlie);
    }

    function test_revert_transferZeroAddress() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        whitelist.transferWhitelistOwnership(id, address(0));
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _createDefault();
        uint256 before_ = treasury.balance;
        whitelist.collectFees();
        assertEq(treasury.balance - before_, CREATE_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentWhitelist.NoFeesToCollect.selector);
        whitelist.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setCreationFee() public {
        vm.prank(owner);
        whitelist.setCreationFee(0.05 ether);
        assertEq(whitelist.creationFee(), 0.05 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        whitelist.setTreasury(newT);
        assertEq(whitelist.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWhitelist.ZeroAddress.selector);
        whitelist.setTreasury(address(0));
    }

    function test_revert_getWhitelistNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentWhitelist.WhitelistNotFound.selector, 999));
        whitelist.getWhitelist(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_createAndAdd(uint8 agentCount) public {
        agentCount = uint8(bound(agentCount, 1, 30));
        uint256 id = _createDefault();

        vm.startPrank(alice);
        for (uint i; i < agentCount; i++) {
            address a = makeAddr(string(abi.encode("agent", i)));
            whitelist.addAgent(id, a);
        }
        vm.stopPrank();

        assertEq(whitelist.getWhitelist(id).agentCount, agentCount);
    }

    function testFuzz_reputationThreshold(uint256 threshold) public {
        threshold = bound(threshold, 1, 500);

        vm.prank(alice);
        uint256 id = whitelist.createWhitelist{value: CREATE_FEE}("Fuzz", false, threshold);

        // alice has score 300
        bool expected = 300 >= threshold;
        assertEq(whitelist.isWhitelisted(id, alice), expected);
    }
}
