// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";

contract AgentRegistryTest is Test {
    ERC20Mock usdc;
    AgentRegistry registry;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");

    uint256 constant REG_FEE = 5_000_000; // $5 USDC (6 decimals)
    uint256 constant RENEW_FEE = 1_000_000; // $1 USDC
    uint256 constant YEAR = 365 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        registry = new AgentRegistry(IERC20(address(usdc)), treasury, owner, REG_FEE, RENEW_FEE);

        // fund agents with USDC and approve
        usdc.mint(agent1, 100_000_000); // $100
        usdc.mint(agent2, 100_000_000);
        usdc.mint(agent3, 100_000_000);

        vm.prank(agent1);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(agent2);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(agent3);
        usdc.approve(address(registry), type(uint256).max);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(registry.paymentToken()), address(usdc));
        assertEq(registry.treasury(), treasury);
        assertEq(registry.owner(), owner);
        assertEq(registry.registrationFee(), REG_FEE);
        assertEq(registry.renewalFee(), RENEW_FEE);
        assertEq(registry.agentCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentRegistry.ZeroAddress.selector);
        new AgentRegistry(IERC20(address(0)), treasury, owner, REG_FEE, RENEW_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentRegistry.ZeroAddress.selector);
        new AgentRegistry(IERC20(address(usdc)), address(0), owner, REG_FEE, RENEW_FEE);
    }

    // ─── Registration ───────────────────────────────────────────────────

    function test_registerAgent() public {
        vm.prank(agent1);
        registry.registerAgent("my-agent", "https://agent1.example.com/api", 1);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.name, "my-agent");
        assertEq(profile.endpoint, "https://agent1.example.com/api");
        assertEq(profile.agentType, 1);
        assertTrue(profile.active);
        assertEq(profile.expiresAt, profile.registeredAt + uint48(YEAR));
        assertEq(registry.agentCount(), 1);
        assertTrue(registry.isRegistered(agent1));
    }

    function test_registerAgent_paysFee() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(agent1);
        registry.registerAgent("fee-agent", "https://api.test", 0);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, REG_FEE);
    }

    function test_registerAgent_nameLookup() public {
        vm.prank(agent1);
        registry.registerAgent("lookup-agent", "https://api.test", 0);

        assertEq(registry.getAgentByName("lookup-agent"), agent1);
    }

    function test_registerMultipleAgents() public {
        vm.prank(agent1);
        registry.registerAgent("agent-one", "https://one.test", 0);
        vm.prank(agent2);
        registry.registerAgent("agent-two", "https://two.test", 1);

        assertEq(registry.agentCount(), 2);
        assertTrue(registry.isRegistered(agent1));
        assertTrue(registry.isRegistered(agent2));
    }

    function test_revert_registerEmptyName() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentRegistry.EmptyName.selector);
        registry.registerAgent("", "https://api.test", 0);
    }

    function test_revert_registerNameTooLong() public {
        // 65 chars
        string memory longName = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        vm.prank(agent1);
        vm.expectRevert(IAgentRegistry.EmptyName.selector);
        registry.registerAgent(longName, "https://api.test", 0);
    }

    function test_revert_registerEmptyEndpoint() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentRegistry.EmptyEndpoint.selector);
        registry.registerAgent("my-agent", "", 0);
    }

    function test_revert_registerInvalidType() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.InvalidAgentType.selector, uint8(11)));
        registry.registerAgent("my-agent", "https://api.test", 11);
    }

    function test_revert_registerDuplicate() public {
        vm.prank(agent1);
        registry.registerAgent("unique-agent", "https://api.test", 0);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.AlreadyRegistered.selector, agent1));
        registry.registerAgent("another-name", "https://api.test", 0);
    }

    function test_revert_registerNameTaken() public {
        vm.prank(agent1);
        registry.registerAgent("taken-name", "https://one.test", 0);

        vm.prank(agent2);
        vm.expectRevert();
        registry.registerAgent("taken-name", "https://two.test", 1);
    }

    // ─── Renewal ────────────────────────────────────────────────────────

    function test_renewRegistration() public {
        vm.prank(agent1);
        registry.registerAgent("renew-agent", "https://api.test", 0);

        IAgentRegistry.AgentProfile memory before = registry.getAgent(agent1);

        // advance 300 days (still valid)
        vm.warp(block.timestamp + 300 days);

        vm.prank(agent1);
        registry.renewRegistration();

        IAgentRegistry.AgentProfile memory after_ = registry.getAgent(agent1);
        // extends from current expiry (not from now)
        assertEq(after_.expiresAt, before.expiresAt + uint48(YEAR));
    }

    function test_renewAfterExpiry() public {
        vm.prank(agent1);
        registry.registerAgent("expired-agent", "https://api.test", 0);

        // advance past expiry
        vm.warp(block.timestamp + YEAR + 30 days);
        assertFalse(registry.isRegistered(agent1));

        vm.prank(agent1);
        registry.renewRegistration();

        assertTrue(registry.isRegistered(agent1));
        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        // renewed from now, not from old expiry
        assertEq(profile.expiresAt, uint48(block.timestamp) + uint48(YEAR));
    }

    function test_renewPaysFee() public {
        vm.prank(agent1);
        registry.registerAgent("pay-agent", "https://api.test", 0);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(agent1);
        registry.renewRegistration();

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, RENEW_FEE);
    }

    function test_revert_renewNotRegistered() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.NotRegistered.selector, agent1));
        registry.renewRegistration();
    }

    // ─── Self-Service ───────────────────────────────────────────────────

    function test_updateEndpoint() public {
        vm.prank(agent1);
        registry.registerAgent("update-agent", "https://old.test", 0);

        vm.prank(agent1);
        registry.updateEndpoint("https://new.test/v2");

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.endpoint, "https://new.test/v2");
    }

    function test_revert_updateEndpointNotRegistered() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.NotRegistered.selector, agent1));
        registry.updateEndpoint("https://new.test");
    }

    function test_revert_updateEndpointEmpty() public {
        vm.prank(agent1);
        registry.registerAgent("endpoint-agent", "https://old.test", 0);

        vm.prank(agent1);
        vm.expectRevert(IAgentRegistry.EmptyEndpoint.selector);
        registry.updateEndpoint("");
    }

    function test_deactivateAgent() public {
        vm.prank(agent1);
        registry.registerAgent("deactivate-me", "https://api.test", 0);

        vm.prank(agent1);
        registry.deactivateAgent();

        assertFalse(registry.isRegistered(agent1));
        assertEq(registry.agentCount(), 0);
        // name should be freed
        assertEq(registry.getAgentByName("deactivate-me"), address(0));
    }

    function test_revert_deactivateNotRegistered() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.NotRegistered.selector, agent1));
        registry.deactivateAgent();
    }

    function test_reRegisterAfterDeactivation() public {
        vm.prank(agent1);
        registry.registerAgent("reuse-name", "https://api.test", 0);

        vm.prank(agent1);
        registry.deactivateAgent();

        // same address can register again
        vm.prank(agent1);
        registry.registerAgent("reuse-name", "https://api2.test", 2);

        assertTrue(registry.isRegistered(agent1));
        assertEq(registry.agentCount(), 1);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_deactivateAgentAdmin() public {
        vm.prank(agent1);
        registry.registerAgent("admin-kill", "https://api.test", 0);

        vm.prank(owner);
        registry.deactivateAgentAdmin(agent1);

        assertFalse(registry.isRegistered(agent1));
        assertEq(registry.agentCount(), 0);
    }

    function test_revert_deactivateAgentAdminNotOwner() public {
        vm.prank(agent1);
        registry.registerAgent("not-admin", "https://api.test", 0);

        vm.prank(agent2);
        vm.expectRevert();
        registry.deactivateAgentAdmin(agent1);
    }

    function test_setRegistrationFee() public {
        vm.prank(owner);
        registry.setRegistrationFee(10_000_000); // $10

        assertEq(registry.registrationFee(), 10_000_000);
    }

    function test_setRenewalFee() public {
        vm.prank(owner);
        registry.setRenewalFee(2_000_000); // $2

        assertEq(registry.renewalFee(), 2_000_000);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        registry.setTreasury(newTreasury);

        assertEq(registry.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentRegistry.ZeroAddress.selector);
        registry.setTreasury(address(0));
    }

    // ─── Pause ──────────────────────────────────────────────────────────

    function test_pauseBlocksRegistration() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(agent1);
        vm.expectRevert();
        registry.registerAgent("paused-agent", "https://api.test", 0);
    }

    function test_pauseBlocksRenewal() public {
        vm.prank(agent1);
        registry.registerAgent("pause-renew", "https://api.test", 0);

        vm.prank(owner);
        registry.pause();

        vm.prank(agent1);
        vm.expectRevert();
        registry.renewRegistration();
    }

    function test_updateEndpointWorksWhenPaused() public {
        vm.prank(agent1);
        registry.registerAgent("pause-update", "https://old.test", 0);

        vm.prank(owner);
        registry.pause();

        // agents can still update their endpoint during pause
        vm.prank(agent1);
        registry.updateEndpoint("https://new.test");

        assertEq(registry.getAgent(agent1).endpoint, "https://new.test");
    }

    function test_deactivateWorksWhenPaused() public {
        vm.prank(agent1);
        registry.registerAgent("pause-deactivate", "https://api.test", 0);

        vm.prank(owner);
        registry.pause();

        // agents can still deactivate during pause
        vm.prank(agent1);
        registry.deactivateAgent();
        assertFalse(registry.getAgent(agent1).active);
    }

    // ─── Expiry ─────────────────────────────────────────────────────────

    function test_isRegisteredExpires() public {
        vm.prank(agent1);
        registry.registerAgent("expiry-test", "https://api.test", 0);

        assertTrue(registry.isRegistered(agent1));

        vm.warp(block.timestamp + YEAR + 1);
        assertFalse(registry.isRegistered(agent1));
    }

    function test_agentProfilePersistsAfterExpiry() public {
        vm.prank(agent1);
        registry.registerAgent("persist-test", "https://api.test", 0);

        vm.warp(block.timestamp + YEAR + 1);

        // profile data still exists
        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.name, "persist-test");
        assertTrue(profile.active); // active flag is still true, just expired
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_registrationFeeCollected(uint256 fee) public {
        fee = bound(fee, 0, 100_000_000); // up to $100 (agent balance)

        vm.prank(owner);
        registry.setRegistrationFee(fee);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(agent1);
        registry.registerAgent("fuzz-agent", "https://fuzz.test", 0);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fee);
    }

    function testFuzz_renewalExtendsCorrectly(uint256 daysElapsed) public {
        daysElapsed = bound(daysElapsed, 1, 730); // 1 day to 2 years

        vm.prank(agent1);
        registry.registerAgent("fuzz-renew", "https://fuzz.test", 0);

        IAgentRegistry.AgentProfile memory before = registry.getAgent(agent1);

        vm.warp(block.timestamp + daysElapsed * 1 days);

        vm.prank(agent1);
        registry.renewRegistration();

        IAgentRegistry.AgentProfile memory after_ = registry.getAgent(agent1);

        if (daysElapsed <= 365) {
            // not expired: extends from old expiry
            assertEq(after_.expiresAt, before.expiresAt + uint48(YEAR));
        } else {
            // expired: extends from now
            assertEq(after_.expiresAt, uint48(block.timestamp) + uint48(YEAR));
        }
    }

    function testFuzz_agentTypeValidation(uint8 agentType) public {
        if (agentType > 10) {
            vm.prank(agent1);
            vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.InvalidAgentType.selector, agentType));
            registry.registerAgent("type-fuzz", "https://fuzz.test", agentType);
        } else {
            vm.prank(agent1);
            registry.registerAgent("type-fuzz", "https://fuzz.test", agentType);
            assertEq(registry.getAgent(agent1).agentType, agentType);
        }
    }
}
