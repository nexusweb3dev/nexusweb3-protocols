// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentStorage} from "../src/AgentStorage.sol";
import {IAgentStorage} from "../src/interfaces/IAgentStorage.sol";

contract AgentStorageTest is Test {
    AgentStorage store;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    uint256 constant WRITE_FEE = 0.0001 ether;
    bytes32 constant KEY1 = keccak256("config");
    bytes32 constant KEY2 = keccak256("state");

    function setUp() public {
        store = new AgentStorage(treasury, owner, WRITE_FEE);
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(store.treasury(), treasury);
        assertEq(store.owner(), owner);
        assertEq(store.writeFee(), WRITE_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentStorage.ZeroAddress.selector);
        new AgentStorage(address(0), owner, WRITE_FEE);
    }

    // ─── Write ──────────────────────────────────────────────────────────

    function test_setValue() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "hello world");

        assertEq(store.getKeyCount(agent1), 1);
        assertTrue(store.keyExists(agent1, KEY1));
    }

    function test_setValueCollectsFee() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "data");

        assertEq(store.accumulatedFees(), WRITE_FEE);
    }

    function test_updateExistingKey() public {
        vm.startPrank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "v1");
        store.setValue{value: WRITE_FEE}(KEY1, "v2");
        vm.stopPrank();

        assertEq(store.getKeyCount(agent1), 1); // still 1 key
        bytes memory val = store.getValuePublic(agent1, KEY1);
        assertEq(string(val), "v2");
    }

    function test_multipleKeys() public {
        vm.startPrank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "a");
        store.setValue{value: WRITE_FEE}(KEY2, "b");
        vm.stopPrank();

        assertEq(store.getKeyCount(agent1), 2);
    }

    function test_differentOwnersShareKeyNames() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "agent1 data");

        vm.prank(agent2);
        store.setValue{value: WRITE_FEE}(KEY1, "agent2 data");

        bytes memory v1 = store.getValuePublic(agent1, KEY1);
        bytes memory v2 = store.getValuePublic(agent2, KEY1);
        assertEq(string(v1), "agent1 data");
        assertEq(string(v2), "agent2 data");
    }

    function test_revert_setValueEmpty() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentStorage.EmptyValue.selector);
        store.setValue{value: WRITE_FEE}(KEY1, "");
    }

    function test_revert_setValueTooLarge() public {
        bytes memory big = new bytes(1025);
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.ValueTooLarge.selector, 1025, 1024));
        store.setValue{value: WRITE_FEE}(KEY1, big);
    }

    function test_revert_setValueInsufficientFee() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.InsufficientFee.selector, WRITE_FEE, 0));
        store.setValue(KEY1, "data");
    }

    function test_revert_setValueMaxKeys() public {
        vm.startPrank(agent1);
        for (uint i; i < 1000; i++) {
            bytes32 k = keccak256(abi.encode(i));
            store.setValue{value: WRITE_FEE}(k, "x");
        }
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.MaxKeysReached.selector, agent1));
        store.setValue{value: WRITE_FEE}(keccak256("overflow"), "x");
        vm.stopPrank();
    }

    function test_revert_setValueWhenPaused() public {
        vm.prank(owner);
        store.pause();

        vm.prank(agent1);
        vm.expectRevert();
        store.setValue{value: WRITE_FEE}(KEY1, "data");
    }

    function test_maxSizeValue() public {
        bytes memory maxVal = new bytes(1024);
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, maxVal);

        bytes memory retrieved = store.getValuePublic(agent1, KEY1);
        assertEq(retrieved.length, 1024);
    }

    // ─── Read ───────────────────────────────────────────────────────────

    function test_ownerCanRead() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "secret");

        vm.prank(agent1);
        bytes memory val = store.getValue(agent1, KEY1);
        assertEq(string(val), "secret");
    }

    function test_revert_readNoAccess() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "secret");

        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.NoReadAccess.selector, agent2, agent1, KEY1));
        store.getValue(agent1, KEY1);
    }

    function test_publicRead() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "public data");

        vm.prank(agent2);
        bytes memory val = store.getValuePublic(agent1, KEY1);
        assertEq(string(val), "public data");
    }

    function test_revert_readKeyNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.KeyNotFound.selector, agent1, KEY1));
        store.getValuePublic(agent1, KEY1);
    }

    // ─── Access Control ─────────────────────────────────────────────────

    function test_grantReadAccess() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "private");

        vm.prank(agent1);
        store.grantReadAccess(KEY1, agent2);

        assertTrue(store.hasReadAccess(agent1, KEY1, agent2));

        vm.prank(agent2);
        bytes memory val = store.getValue(agent1, KEY1);
        assertEq(string(val), "private");
    }

    function test_revokeReadAccess() public {
        vm.startPrank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "private");
        store.grantReadAccess(KEY1, agent2);
        store.revokeReadAccess(KEY1, agent2);
        vm.stopPrank();

        assertFalse(store.hasReadAccess(agent1, KEY1, agent2));

        vm.prank(agent2);
        vm.expectRevert();
        store.getValue(agent1, KEY1);
    }

    function test_revert_grantAccessKeyNotFound() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.KeyNotFound.selector, agent1, KEY1));
        store.grantReadAccess(KEY1, agent2);
    }

    function test_revert_grantAccessZeroReader() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "data");

        vm.prank(agent1);
        vm.expectRevert(IAgentStorage.ZeroAddress.selector);
        store.grantReadAccess(KEY1, address(0));
    }

    function test_ownerAlwaysHasReadAccess() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "mine");

        assertTrue(store.hasReadAccess(agent1, KEY1, agent1));
    }

    // ─── Delete ─────────────────────────────────────────────────────────

    function test_deleteValue() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "temp");

        uint256 balBefore = agent1.balance;

        vm.prank(agent1);
        store.deleteValue(KEY1);

        assertFalse(store.keyExists(agent1, KEY1));
        assertEq(store.getKeyCount(agent1), 0);

        uint256 expectedRefund = WRITE_FEE * 5000 / 10_000;
        assertEq(agent1.balance - balBefore, expectedRefund);
    }

    function test_revert_deleteKeyNotFound() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentStorage.KeyNotFound.selector, agent1, KEY1));
        store.deleteValue(KEY1);
    }

    function test_deleteFreesKeySlot() public {
        vm.startPrank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "a");
        store.deleteValue(KEY1);
        store.setValue{value: WRITE_FEE}(KEY1, "b");
        vm.stopPrank();

        assertEq(store.getKeyCount(agent1), 1);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(KEY1, "data");

        uint256 treasuryBefore = treasury.balance;
        store.collectFees();
        assertEq(treasury.balance - treasuryBefore, WRITE_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentStorage.NoFeesToCollect.selector);
        store.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setWriteFee() public {
        vm.prank(owner);
        store.setWriteFee(0.0005 ether);
        assertEq(store.writeFee(), 0.0005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        store.setTreasury(newT);
        assertEq(store.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentStorage.ZeroAddress.selector);
        store.setTreasury(address(0));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_writeAndRead(bytes32 key, bytes calldata value) public {
        vm.assume(value.length > 0 && value.length <= 1024);

        vm.prank(agent1);
        store.setValue{value: WRITE_FEE}(key, value);

        bytes memory retrieved = store.getValuePublic(agent1, key);
        assertEq(keccak256(retrieved), keccak256(value));
    }

    function testFuzz_deleteRefunds(uint8 writeCount) public {
        writeCount = uint8(bound(writeCount, 1, 20));

        bytes32[] memory keys = new bytes32[](writeCount);
        vm.startPrank(agent1);
        for (uint i; i < writeCount; i++) {
            keys[i] = keccak256(abi.encode("key", i));
            store.setValue{value: WRITE_FEE}(keys[i], "v");
        }

        uint256 balBefore = agent1.balance;
        for (uint i; i < writeCount; i++) {
            store.deleteValue(keys[i]);
        }
        vm.stopPrank();

        uint256 expectedRefund = (WRITE_FEE * 5000 / 10_000) * writeCount;
        assertEq(agent1.balance - balBefore, expectedRefund);
        assertEq(store.getKeyCount(agent1), 0);
    }
}
