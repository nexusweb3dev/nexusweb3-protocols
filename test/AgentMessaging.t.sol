// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentMessaging} from "../src/AgentMessaging.sol";
import {IAgentMessaging} from "../src/interfaces/IAgentMessaging.sol";

contract AgentMessagingTest is Test {
    AgentMessaging messaging;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant MSG_FEE = 0.0001 ether;
    bytes32 constant SUBJECT = keccak256("hello");

    function setUp() public {
        messaging = new AgentMessaging(treasury, owner, MSG_FEE);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
    }

    function _sendDefault() internal returns (uint256) {
        vm.prank(alice);
        return messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "hey bob");
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(messaging.treasury(), treasury);
        assertEq(messaging.owner(), owner);
        assertEq(messaging.messageFee(), MSG_FEE);
        assertEq(messaging.messageCount(), 0);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentMessaging.ZeroAddress.selector);
        new AgentMessaging(address(0), owner, MSG_FEE);
    }

    // ─── Send ───────────────────────────────────────────────────────────

    function test_sendMessage() public {
        uint256 id = _sendDefault();

        assertEq(id, 0);
        assertEq(messaging.messageCount(), 1);

        IAgentMessaging.Message memory m = messaging.getMessage(id);
        assertEq(m.sender, alice);
        assertEq(m.recipient, bob);
        assertEq(m.subject, SUBJECT);
        assertEq(string(m.content), "hey bob");
        assertEq(m.readAt, 0);
        assertFalse(m.deleted);
    }

    function test_sendCollectsFee() public {
        _sendDefault();
        assertEq(messaging.accumulatedFees(), MSG_FEE);
    }

    function test_sendAppearsInInbox() public {
        _sendDefault();

        assertEq(messaging.getInboxCount(bob), 1);
        uint256[] memory inbox = messaging.getInbox(bob, 0, 10);
        assertEq(inbox[0], 0);
    }

    function test_sendAppearsInSent() public {
        _sendDefault();

        assertEq(messaging.getSentCount(alice), 1);
        uint256[] memory sent = messaging.getSent(alice, 0, 10);
        assertEq(sent[0], 0);
    }

    function test_sendMultiple() public {
        vm.startPrank(alice);
        messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "msg1");
        messaging.sendMessage{value: MSG_FEE}(charlie, SUBJECT, "msg2");
        vm.stopPrank();

        assertEq(messaging.messageCount(), 2);
        assertEq(messaging.getInboxCount(bob), 1);
        assertEq(messaging.getInboxCount(charlie), 1);
        assertEq(messaging.getSentCount(alice), 2);
    }

    function test_revert_sendToSelf() public {
        vm.prank(alice);
        vm.expectRevert(IAgentMessaging.InvalidRecipient.selector);
        messaging.sendMessage{value: MSG_FEE}(alice, SUBJECT, "self");
    }

    function test_revert_sendToZero() public {
        vm.prank(alice);
        vm.expectRevert(IAgentMessaging.InvalidRecipient.selector);
        messaging.sendMessage{value: MSG_FEE}(address(0), SUBJECT, "zero");
    }

    function test_revert_sendEmptyContent() public {
        vm.prank(alice);
        vm.expectRevert(IAgentMessaging.EmptyContent.selector);
        messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "");
    }

    function test_revert_sendContentTooLarge() public {
        bytes memory big = new bytes(10_241);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.ContentTooLarge.selector, 10_241, 10_240));
        messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, big);
    }

    function test_revert_sendInsufficientFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.InsufficientFee.selector, MSG_FEE, 0));
        messaging.sendMessage(bob, SUBJECT, "cheap");
    }

    function test_revert_sendWhenPaused() public {
        vm.prank(owner);
        messaging.pause();

        vm.prank(alice);
        vm.expectRevert();
        messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "paused");
    }

    function test_maxContentSize() public {
        bytes memory maxContent = new bytes(10_240);
        vm.prank(alice);
        messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, maxContent);

        IAgentMessaging.Message memory m = messaging.getMessage(0);
        assertEq(m.content.length, 10_240);
    }

    // ─── Reply ──────────────────────────────────────────────────────────

    function test_replyTo() public {
        uint256 origId = _sendDefault(); // alice → bob

        vm.prank(bob);
        uint256 replyId = messaging.replyTo{value: MSG_FEE}(origId, "hey alice!");

        IAgentMessaging.Message memory reply = messaging.getMessage(replyId);
        assertEq(reply.sender, bob);
        assertEq(reply.recipient, alice); // reply goes back to sender
        assertEq(reply.replyToId, origId);
        assertEq(reply.subject, SUBJECT); // inherits subject
    }

    function test_replyChain() public {
        uint256 id0 = _sendDefault(); // alice → bob

        vm.prank(bob);
        uint256 id1 = messaging.replyTo{value: MSG_FEE}(id0, "reply 1");

        vm.prank(alice);
        uint256 id2 = messaging.replyTo{value: MSG_FEE}(id1, "reply 2");

        assertEq(messaging.getMessage(id2).replyToId, id1);
        assertEq(messaging.getMessage(id2).recipient, bob);
    }

    function test_revert_replyInvalidTarget() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.InvalidReplyTarget.selector, 999));
        messaging.replyTo{value: MSG_FEE}(999, "ghost");
    }

    function test_revert_replyToDeleted() public {
        uint256 id = _sendDefault();

        vm.prank(alice);
        messaging.deleteMessage(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.InvalidReplyTarget.selector, id));
        messaging.replyTo{value: MSG_FEE}(id, "deleted");
    }

    // ─── Read ───────────────────────────────────────────────────────────

    function test_markRead() public {
        uint256 id = _sendDefault();

        vm.prank(bob);
        messaging.markRead(id);

        IAgentMessaging.Message memory m = messaging.getMessage(id);
        assertGt(m.readAt, 0);
    }

    function test_revert_markReadNotRecipient() public {
        uint256 id = _sendDefault();

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.NotRecipient.selector, id));
        messaging.markRead(id);
    }

    function test_revert_markReadAlready() public {
        uint256 id = _sendDefault();

        vm.prank(bob);
        messaging.markRead(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.AlreadyRead.selector, id));
        messaging.markRead(id);
    }

    function test_revert_markReadNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.MessageNotFound.selector, 999));
        messaging.markRead(999);
    }

    // ─── Delete ─────────────────────────────────────────────────────────

    function test_deleteMessage() public {
        uint256 id = _sendDefault();

        vm.prank(alice);
        messaging.deleteMessage(id);

        assertTrue(messaging.getMessage(id).deleted);
    }

    function test_revert_deleteNotSender() public {
        uint256 id = _sendDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.NotSender.selector, id));
        messaging.deleteMessage(id);
    }

    function test_revert_deleteAlready() public {
        uint256 id = _sendDefault();

        vm.prank(alice);
        messaging.deleteMessage(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.AlreadyDeleted.selector, id));
        messaging.deleteMessage(id);
    }

    // ─── Pagination ─────────────────────────────────────────────────────

    function test_inboxPagination() public {
        vm.startPrank(alice);
        for (uint i; i < 5; i++) {
            messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "msg");
        }
        vm.stopPrank();

        uint256[] memory page1 = messaging.getInbox(bob, 0, 3);
        assertEq(page1.length, 3);

        uint256[] memory page2 = messaging.getInbox(bob, 3, 3);
        assertEq(page2.length, 2);
    }

    function test_inboxOffsetBeyondLength() public {
        _sendDefault();
        uint256[] memory empty = messaging.getInbox(bob, 100, 10);
        assertEq(empty.length, 0);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        _sendDefault();
        uint256 treasuryBefore = treasury.balance;
        messaging.collectFees();
        assertEq(treasury.balance - treasuryBefore, MSG_FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentMessaging.NoFeesToCollect.selector);
        messaging.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setMessageFee() public {
        vm.prank(owner);
        messaging.setMessageFee(0.0005 ether);
        assertEq(messaging.messageFee(), 0.0005 ether);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        messaging.setTreasury(newT);
        assertEq(messaging.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentMessaging.ZeroAddress.selector);
        messaging.setTreasury(address(0));
    }

    function test_revert_getMessageNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentMessaging.MessageNotFound.selector, 999));
        messaging.getMessage(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_sendAndRetrieve(bytes32 subj, bytes calldata content) public {
        vm.assume(content.length > 0 && content.length <= 10_240);

        vm.prank(alice);
        uint256 id = messaging.sendMessage{value: MSG_FEE}(bob, subj, content);

        IAgentMessaging.Message memory m = messaging.getMessage(id);
        assertEq(m.subject, subj);
        assertEq(keccak256(m.content), keccak256(content));
    }

    function testFuzz_feeAccumulates(uint8 count) public {
        count = uint8(bound(count, 1, 30));

        vm.startPrank(alice);
        for (uint i; i < count; i++) {
            messaging.sendMessage{value: MSG_FEE}(bob, SUBJECT, "m");
        }
        vm.stopPrank();

        assertEq(messaging.accumulatedFees(), uint256(count) * MSG_FEE);
    }
}
