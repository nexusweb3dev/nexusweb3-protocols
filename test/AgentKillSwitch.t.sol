// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentKillSwitch} from "../src/AgentKillSwitch.sol";
import {IAgentKillSwitch} from "../src/interfaces/IAgentKillSwitch.sol";

contract AgentKillSwitchTest is Test {
    AgentKillSwitch ks;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agentOwner = makeAddr("agentOwner");
    address agent = makeAddr("agent");
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    uint256 constant REG_FEE = 0.01 ether;
    uint256 constant SPEND_LIMIT = 1_000_000_000; // $1000 USDC
    uint256 constant TX_LIMIT = 100;
    uint48 constant SESSION = 1 hours;

    function setUp() public {
        ks = new AgentKillSwitch(treasury, owner, REG_FEE);
        vm.deal(agentOwner, 10 ether);
        vm.deal(agent, 1 ether);
    }

    function _register() internal {
        vm.prank(agentOwner);
        ks.registerAgent{value: REG_FEE}(agent, SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(ks.treasury(), treasury);
        assertEq(ks.owner(), owner);
        assertEq(ks.registrationFee(), REG_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentKillSwitch.ZeroAddress.selector);
        new AgentKillSwitch(address(0), owner, REG_FEE);
    }

    // ─── Register ───────────────────────────────────────────────────────

    function test_registerAgent() public {
        _register();

        assertTrue(ks.isActive(agent));

        IAgentKillSwitch.AgentConfig memory c = ks.getAgentConfig(agent);
        assertEq(c.agentOwner, agentOwner);
        assertEq(c.spendingLimit, SPEND_LIMIT);
        assertEq(c.txLimit, TX_LIMIT);
        assertEq(c.sessionDuration, SESSION);
        assertTrue(c.active);
        assertFalse(c.paused);
    }

    function test_registerCollectsFee() public {
        _register();
        assertEq(ks.accumulatedFees(), REG_FEE);
    }

    function test_revert_registerDuplicate() public {
        _register();
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentAlreadyRegistered.selector, agent));
        ks.registerAgent{value: REG_FEE}(agent, SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    function test_revert_registerZeroAgent() public {
        vm.prank(agentOwner);
        vm.expectRevert(IAgentKillSwitch.ZeroAddress.selector);
        ks.registerAgent{value: REG_FEE}(address(0), SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    function test_revert_registerInvalidConfig() public {
        vm.prank(agentOwner);
        vm.expectRevert(IAgentKillSwitch.InvalidConfig.selector);
        ks.registerAgent{value: REG_FEE}(agent, 0, TX_LIMIT, SESSION);
    }

    function test_revert_registerInsufficientFee() public {
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.InsufficientFee.selector, REG_FEE, 0));
        ks.registerAgent(agent, SPEND_LIMIT, TX_LIMIT, SESSION);
    }

    // ─── Kill Switch ────────────────────────────────────────────────────

    function test_killSwitch() public {
        _register();

        vm.prank(agentOwner);
        ks.killSwitch(agent);

        assertFalse(ks.isActive(agent));

        IAgentKillSwitch.KillEvent[] memory history = ks.getKillHistory(agent);
        assertEq(history.length, 1);
        assertEq(history[0].killedBy, agentOwner);
    }

    function test_killSwitchByMultisig() public {
        _register();

        vm.prank(agentOwner);
        ks.setEmergencyMultisig(agent, multisig);

        vm.prank(multisig);
        ks.killSwitch(agent);

        assertFalse(ks.isActive(agent));
    }

    function test_killSwitchSameBlock() public {
        _register();

        // register and kill in same block — must work
        vm.prank(agentOwner);
        ks.killSwitch(agent);

        assertFalse(ks.isActive(agent));
        assertEq(ks.getKillHistory(agent)[0].timestamp, uint48(block.timestamp));
    }

    function test_revert_killSwitchByAgent() public {
        _register();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentCannotKillItself.selector, agent));
        ks.killSwitch(agent);
    }

    function test_revert_killSwitchByStranger() public {
        _register();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.NotOwnerOrMultisig.selector, agent, stranger));
        ks.killSwitch(agent);
    }

    function test_revert_killAlreadyKilled() public {
        _register();

        vm.prank(agentOwner);
        ks.killSwitch(agent);

        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentIsKilled.selector, agent));
        ks.killSwitch(agent);
    }

    function test_revert_killNotRegistered() public {
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentNotRegistered.selector, agent));
        ks.killSwitch(agent);
    }

    // ─── Pause / Resume ─────────────────────────────────────────────────

    function test_pauseAgent() public {
        _register();

        vm.prank(agentOwner);
        ks.pauseAgent(agent);

        assertFalse(ks.isActive(agent));
        assertTrue(ks.getAgentConfig(agent).paused);
    }

    function test_pauseByMultisig() public {
        _register();
        vm.prank(agentOwner);
        ks.setEmergencyMultisig(agent, multisig);

        vm.prank(multisig);
        ks.pauseAgent(agent);
        assertTrue(ks.getAgentConfig(agent).paused);
    }

    function test_resumeAgent() public {
        _register();

        vm.prank(agentOwner);
        ks.pauseAgent(agent);

        vm.prank(agentOwner);
        ks.resumeAgent(agent);

        assertTrue(ks.isActive(agent));
        assertFalse(ks.getAgentConfig(agent).paused);
    }

    function test_revert_resumeByMultisig() public {
        _register();
        vm.prank(agentOwner);
        ks.setEmergencyMultisig(agent, multisig);
        vm.prank(agentOwner);
        ks.pauseAgent(agent);

        // multisig CANNOT resume — only owner
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.NotAgentOwner.selector, agent, multisig));
        ks.resumeAgent(agent);
    }

    function test_revert_resumeKilledAgent() public {
        _register();
        vm.prank(agentOwner);
        ks.killSwitch(agent);

        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentIsKilled.selector, agent));
        ks.resumeAgent(agent);
    }

    // ─── Session ────────────────────────────────────────────────────────

    function test_sessionExpiry() public {
        _register();

        assertTrue(ks.isSessionValid(agent));

        vm.warp(block.timestamp + SESSION + 1);
        assertFalse(ks.isSessionValid(agent));
    }

    function test_resetSession() public {
        _register();

        // use some tx
        ks.checkAndDecrementTx(agent);
        ks.checkAndDecrementTx(agent);

        vm.prank(agentOwner);
        ks.resetSession(agent);

        IAgentKillSwitch.AgentConfig memory c = ks.getAgentConfig(agent);
        assertEq(c.txCount, 0);
        assertEq(c.spendingUsed, 0);
    }

    function test_revert_resetSessionNotOwner() public {
        _register();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.NotAgentOwner.selector, agent, stranger));
        ks.resetSession(agent);
    }

    // ─── Protocol Integration ───────────────────────────────────────────

    function test_checkAndDecrementTx() public {
        _register();

        ks.checkAndDecrementTx(agent);
        assertEq(ks.getAgentConfig(agent).txCount, 1);

        ks.checkAndDecrementTx(agent);
        assertEq(ks.getAgentConfig(agent).txCount, 2);
    }

    function test_revert_txLimitExceeded() public {
        vm.prank(agentOwner);
        ks.registerAgent{value: REG_FEE}(agent, SPEND_LIMIT, 2, SESSION); // only 2 tx allowed

        ks.checkAndDecrementTx(agent);
        ks.checkAndDecrementTx(agent);

        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.TxLimitExceeded.selector, agent));
        ks.checkAndDecrementTx(agent);
    }

    function test_checkAndDecrementSpending() public {
        _register();

        ks.checkAndDecrementSpending(agent, 500_000_000);
        assertEq(ks.getAgentConfig(agent).spendingUsed, 500_000_000);
    }

    function test_revert_spendingLimitExceeded() public {
        _register();

        ks.checkAndDecrementSpending(agent, 800_000_000);

        vm.expectRevert();
        ks.checkAndDecrementSpending(agent, 300_000_000); // 800 + 300 > 1000
    }

    function test_revert_checkKilledAgent() public {
        _register();
        vm.prank(agentOwner);
        ks.killSwitch(agent);

        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentIsKilled.selector, agent));
        ks.checkAndDecrementTx(agent);
    }

    function test_revert_checkPausedAgent() public {
        _register();
        vm.prank(agentOwner);
        ks.pauseAgent(agent);

        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentIsPaused.selector, agent));
        ks.checkAndDecrementTx(agent);
    }

    function test_revert_checkExpiredSession() public {
        _register();
        vm.warp(block.timestamp + SESSION + 1);

        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.SessionExpired.selector, agent));
        ks.checkAndDecrementTx(agent);
    }

    // ─── Emergency Multisig ─────────────────────────────────────────────

    function test_setEmergencyMultisig() public {
        _register();

        vm.prank(agentOwner);
        ks.setEmergencyMultisig(agent, multisig);

        assertEq(ks.getEmergencyMultisig(agent), multisig);
    }

    function test_revert_setMultisigNotOwner() public {
        _register();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.NotAgentOwner.selector, agent, stranger));
        ks.setEmergencyMultisig(agent, multisig);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _register();
        uint256 before_ = treasury.balance;
        ks.collectFees();
        assertEq(treasury.balance - before_, REG_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentKillSwitch.NoFeesToCollect.selector);
        ks.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setRegistrationFee() public {
        vm.prank(owner);
        ks.setRegistrationFee(0.02 ether);
        assertEq(ks.registrationFee(), 0.02 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        ks.setTreasury(newT);
        assertEq(ks.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentKillSwitch.ZeroAddress.selector);
        ks.setTreasury(address(0));
    }

    function test_revert_getConfigNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitch.AgentNotRegistered.selector, agent));
        ks.getAgentConfig(agent);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_txCountTracking(uint8 txCount) public {
        txCount = uint8(bound(txCount, 1, 100));
        _register();

        for (uint i; i < txCount; i++) {
            ks.checkAndDecrementTx(agent);
        }
        assertEq(ks.getAgentConfig(agent).txCount, txCount);
    }

    function testFuzz_spendingTracking(uint256 amount) public {
        amount = bound(amount, 1, SPEND_LIMIT);
        _register();

        ks.checkAndDecrementSpending(agent, amount);
        assertEq(ks.getAgentConfig(agent).spendingUsed, amount);
    }

    function testFuzz_killAlwaysWorks(uint48 delay) public {
        delay = uint48(bound(delay, 0, 365 days));
        _register();

        vm.warp(block.timestamp + delay);

        vm.prank(agentOwner);
        ks.killSwitch(agent);
        assertFalse(ks.isActive(agent));
    }
}
