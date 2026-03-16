// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBridge} from "../src/AgentBridge.sol";
import {IAgentBridge} from "../src/interfaces/IAgentBridge.sol";

contract AgentBridgeTest is Test {
    AgentBridge bridge;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address relayer = makeAddr("relayer");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address stranger = makeAddr("stranger");

    uint256 constant BRIDGE_FEE = 0.001 ether;
    uint256 constant BASE_CHAIN = 8453;
    uint256 constant ARBITRUM_CHAIN = 42161;
    uint256 constant OPTIMISM_CHAIN = 10;
    uint256 constant POLYGON_CHAIN = 137;
    uint256 constant BNB_CHAIN = 56;
    uint256 constant UNSUPPORTED_CHAIN = 999;

    function setUp() public {
        bridge = new AgentBridge(treasury, relayer, owner, BRIDGE_FEE);

        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(bridge.treasury(), treasury);
        assertEq(bridge.relayer(), relayer);
        assertEq(bridge.owner(), owner);
        assertEq(bridge.bridgeFee(), BRIDGE_FEE);
        assertEq(bridge.accumulatedFees(), 0);
        assertTrue(bridge.supportedChains(BASE_CHAIN));
        assertTrue(bridge.supportedChains(ARBITRUM_CHAIN));
        assertTrue(bridge.supportedChains(OPTIMISM_CHAIN));
        assertTrue(bridge.supportedChains(POLYGON_CHAIN));
        assertTrue(bridge.supportedChains(BNB_CHAIN));
        assertFalse(bridge.supportedChains(UNSUPPORTED_CHAIN));
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentBridge.ZeroAddress.selector);
        new AgentBridge(address(0), relayer, owner, BRIDGE_FEE);
    }

    function test_revert_constructorZeroRelayer() public {
        vm.expectRevert(IAgentBridge.ZeroAddress.selector);
        new AgentBridge(treasury, address(0), owner, BRIDGE_FEE);
    }

    // ─── Register Cross-Chain ───────────────────────────────────────────

    function test_registerCrossChain() public {
        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        assertTrue(bridge.isBridgedTo(agent1, ARBITRUM_CHAIN));
        assertEq(bridge.accumulatedFees(), BRIDGE_FEE);

        bytes32 expectedHash = keccak256(abi.encode(agent1, block.chainid));
        assertEq(bridge.getIdentityHash(agent1), expectedHash);
    }

    function test_registerCrossChain_multipleChains() public {
        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(OPTIMISM_CHAIN);

        assertTrue(bridge.isBridgedTo(agent1, ARBITRUM_CHAIN));
        assertTrue(bridge.isBridgedTo(agent1, OPTIMISM_CHAIN));
        assertEq(bridge.accumulatedFees(), BRIDGE_FEE * 2);
    }

    function test_registerCrossChain_overpayAccepted() public {
        uint256 overpay = BRIDGE_FEE * 2;

        vm.prank(agent1);
        bridge.registerCrossChain{value: overpay}(BASE_CHAIN);

        assertTrue(bridge.isBridgedTo(agent1, BASE_CHAIN));
        assertEq(bridge.accumulatedFees(), overpay);
    }

    function test_revert_registerUnsupportedChain() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.UnsupportedChain.selector, UNSUPPORTED_CHAIN));
        bridge.registerCrossChain{value: BRIDGE_FEE}(UNSUPPORTED_CHAIN);
    }

    function test_revert_registerAlreadyBridged() public {
        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.AlreadyBridged.selector, agent1, ARBITRUM_CHAIN));
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);
    }

    function test_revert_registerInsufficientFee() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.InsufficientFee.selector, BRIDGE_FEE, BRIDGE_FEE - 1));
        bridge.registerCrossChain{value: BRIDGE_FEE - 1}(ARBITRUM_CHAIN);
    }

    function test_revert_registerWhenPaused() public {
        vm.prank(owner);
        bridge.pause();

        vm.prank(agent1);
        vm.expectRevert();
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);
    }

    // ─── Verify From Bridge ─────────────────────────────────────────────

    function test_verifyFromBridge() public {
        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(relayer);
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);

        assertTrue(bridge.isVerifiedFromChain(agent1, ARBITRUM_CHAIN));
        assertEq(bridge.getIdentityHash(agent1), idHash);
    }

    function test_revert_verifyFromBridgeNotRelayer() public {
        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.NotRelayer.selector, stranger));
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);
    }

    function test_revert_verifyFromBridgeUnsupportedChain() public {
        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.UnsupportedChain.selector, UNSUPPORTED_CHAIN));
        bridge.verifyFromBridge(agent1, idHash, UNSUPPORTED_CHAIN);
    }

    function test_revert_verifyFromBridgeAlreadyVerified() public {
        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(relayer);
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.AlreadyVerified.selector, agent1, ARBITRUM_CHAIN));
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);
    }

    function test_revert_verifyWhenPaused() public {
        vm.prank(owner);
        bridge.pause();

        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(relayer);
        vm.expectRevert();
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        vm.prank(agent2);
        bridge.registerCrossChain{value: BRIDGE_FEE}(OPTIMISM_CHAIN);

        uint256 totalFees = BRIDGE_FEE * 2;
        uint256 treasuryBefore = treasury.balance;

        bridge.collectFees();

        assertEq(treasury.balance - treasuryBefore, totalFees);
        assertEq(bridge.accumulatedFees(), 0);
    }

    function test_revert_collectFeesNoFees() public {
        vm.expectRevert(IAgentBridge.NoFeesToCollect.selector);
        bridge.collectFees();
    }

    // ─── Chain Management ───────────────────────────────────────────────

    function test_addChain() public {
        uint256 newChain = 43114; // Avalanche

        vm.prank(owner);
        bridge.addChain(newChain);

        assertTrue(bridge.supportedChains(newChain));
    }

    function test_revert_addChainAlreadySupported() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.ChainAlreadySupported.selector, BASE_CHAIN));
        bridge.addChain(BASE_CHAIN);
    }

    function test_revert_addChainNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bridge.addChain(43114);
    }

    function test_removeChain() public {
        vm.prank(owner);
        bridge.removeChain(BNB_CHAIN);

        assertFalse(bridge.supportedChains(BNB_CHAIN));
    }

    function test_revert_removeChainNotSupported() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.ChainNotSupported.selector, UNSUPPORTED_CHAIN));
        bridge.removeChain(UNSUPPORTED_CHAIN);
    }

    function test_registerFailsAfterChainRemoved() public {
        vm.prank(owner);
        bridge.removeChain(POLYGON_CHAIN);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.UnsupportedChain.selector, POLYGON_CHAIN));
        bridge.registerCrossChain{value: BRIDGE_FEE}(POLYGON_CHAIN);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setRelayer() public {
        address newRelayer = makeAddr("newRelayer");

        vm.prank(owner);
        bridge.setRelayer(newRelayer);

        assertEq(bridge.relayer(), newRelayer);
    }

    function test_revert_setRelayerZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentBridge.ZeroAddress.selector);
        bridge.setRelayer(address(0));
    }

    function test_setBridgeFee() public {
        uint256 newFee = 0.01 ether;

        vm.prank(owner);
        bridge.setBridgeFee(newFee);

        assertEq(bridge.bridgeFee(), newFee);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        bridge.setTreasury(newTreasury);

        assertEq(bridge.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentBridge.ZeroAddress.selector);
        bridge.setTreasury(address(0));
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        bridge.pause();

        vm.prank(agent1);
        vm.expectRevert();
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        vm.prank(owner);
        bridge.unpause();

        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);
        assertTrue(bridge.isBridgedTo(agent1, ARBITRUM_CHAIN));
    }

    // ─── Replay Protection ──────────────────────────────────────────────

    function test_replayProtection_register() public {
        vm.prank(agent1);
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.AlreadyBridged.selector, agent1, ARBITRUM_CHAIN));
        bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);
    }

    function test_replayProtection_verify() public {
        bytes32 idHash = keccak256(abi.encode(agent1, uint256(1)));

        vm.prank(relayer);
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.AlreadyVerified.selector, agent1, ARBITRUM_CHAIN));
        bridge.verifyFromBridge(agent1, idHash, ARBITRUM_CHAIN);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_bridgeFees(uint256 fee) public {
        fee = bound(fee, 0.0001 ether, 1 ether);

        vm.prank(owner);
        bridge.setBridgeFee(fee);

        vm.prank(agent1);
        bridge.registerCrossChain{value: fee}(ARBITRUM_CHAIN);

        assertEq(bridge.accumulatedFees(), fee);
        assertEq(address(bridge).balance, fee);
    }

    function testFuzz_bridgeFeeInsufficientRevert(uint256 fee, uint256 paid) public {
        fee = bound(fee, 0.001 ether, 1 ether);
        paid = bound(paid, 0, fee - 1);

        vm.prank(owner);
        bridge.setBridgeFee(fee);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentBridge.InsufficientFee.selector, fee, paid));
        bridge.registerCrossChain{value: paid}(ARBITRUM_CHAIN);
    }

    function testFuzz_multipleAgentsBridge(uint8 agentCount) public {
        agentCount = uint8(bound(agentCount, 1, 20));
        uint256 totalFees;

        for (uint8 i = 0; i < agentCount; i++) {
            address agent = makeAddr(string(abi.encodePacked("fuzzAgent", i)));
            vm.deal(agent, 1 ether);

            vm.prank(agent);
            bridge.registerCrossChain{value: BRIDGE_FEE}(ARBITRUM_CHAIN);
            totalFees += BRIDGE_FEE;
        }

        assertEq(bridge.accumulatedFees(), totalFees);
    }
}
