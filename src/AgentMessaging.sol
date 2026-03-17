// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentMessaging} from "./interfaces/IAgentMessaging.sol";

/// @notice On-chain messaging between AI agents. Permanent audit trail, sender-pays model.
contract AgentMessaging is Ownable, ReentrancyGuard, Pausable, IAgentMessaging {
    uint256 public constant MAX_CONTENT_SIZE = 10_240; // 10KB

    uint256 public messageFee;
    address public treasury;
    uint256 public messageCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Message) private _messages;
    mapping(address => uint256[]) private _inbox;
    mapping(address => uint256[]) private _sent;

    constructor(address treasury_, address owner_, uint256 messageFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        messageFee = messageFee_;
    }

    // ─── Send ───────────────────────────────────────────────────────────

    /// @notice Send a message to another agent.
    function sendMessage(
        address recipient,
        bytes32 subject,
        bytes calldata content
    ) external payable nonReentrant whenNotPaused returns (uint256 messageId) {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (content.length == 0) revert EmptyContent();
        if (content.length > MAX_CONTENT_SIZE) revert ContentTooLarge(content.length, MAX_CONTENT_SIZE);
        if (msg.value < messageFee) revert InsufficientFee(messageFee, msg.value);

        messageId = messageCount++;
        _messages[messageId] = Message({
            sender: msg.sender,
            recipient: recipient,
            subject: subject,
            content: content,
            sentAt: uint48(block.timestamp),
            readAt: 0,
            replyToId: type(uint256).max, // sentinel = no reply
            deleted: false
        });

        _inbox[recipient].push(messageId);
        _sent[msg.sender].push(messageId);
        accumulatedFees += msg.value;

        emit MessageSent(messageId, msg.sender, recipient, subject);
    }

    /// @notice Reply to an existing message. Creates a threaded conversation.
    function replyTo(
        uint256 originalMessageId,
        bytes calldata content
    ) external payable nonReentrant whenNotPaused returns (uint256 messageId) {
        if (originalMessageId >= messageCount) revert InvalidReplyTarget(originalMessageId);
        Message storage orig = _messages[originalMessageId];
        if (orig.deleted) revert InvalidReplyTarget(originalMessageId);

        // reply goes back to the original sender
        address recipient = orig.sender == msg.sender ? orig.recipient : orig.sender;
        if (recipient == msg.sender) revert InvalidRecipient();

        if (content.length == 0) revert EmptyContent();
        if (content.length > MAX_CONTENT_SIZE) revert ContentTooLarge(content.length, MAX_CONTENT_SIZE);
        if (msg.value < messageFee) revert InsufficientFee(messageFee, msg.value);

        messageId = messageCount++;
        _messages[messageId] = Message({
            sender: msg.sender,
            recipient: recipient,
            subject: orig.subject,
            content: content,
            sentAt: uint48(block.timestamp),
            readAt: 0,
            replyToId: originalMessageId,
            deleted: false
        });

        _inbox[recipient].push(messageId);
        _sent[msg.sender].push(messageId);
        accumulatedFees += msg.value;

        emit MessageSent(messageId, msg.sender, recipient, orig.subject);
    }

    // ─── Read ───────────────────────────────────────────────────────────

    /// @notice Mark a message as read. Only recipient can call.
    function markRead(uint256 messageId) external {
        if (messageId >= messageCount) revert MessageNotFound(messageId);
        Message storage m = _messages[messageId];
        if (m.recipient != msg.sender) revert NotRecipient(messageId);
        if (m.readAt > 0) revert AlreadyRead(messageId);

        m.readAt = uint48(block.timestamp);
        emit MessageRead(messageId, m.readAt);
    }

    // ─── Delete ─────────────────────────────────────────────────────────

    /// @notice Soft-delete a message. Only sender can delete.
    function deleteMessage(uint256 messageId) external {
        if (messageId >= messageCount) revert MessageNotFound(messageId);
        Message storage m = _messages[messageId];
        if (m.sender != msg.sender) revert NotSender(messageId);
        if (m.deleted) revert AlreadyDeleted(messageId);

        m.deleted = true;
        emit MessageDeleted(messageId);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect accumulated fees to treasury.
    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Fee transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setMessageFee(uint256 newFee) external onlyOwner {
        uint256 old = messageFee;
        messageFee = newFee;
        emit MessageFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getMessage(uint256 messageId) external view returns (Message memory) {
        if (messageId >= messageCount) revert MessageNotFound(messageId);
        return _messages[messageId];
    }

    function getInboxCount(address recipient) external view returns (uint256) {
        return _inbox[recipient].length;
    }

    function getInbox(address recipient, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] storage ids = _inbox[recipient];
        if (offset >= ids.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = ids[i];
        }
        return result;
    }

    function getSentCount(address sender) external view returns (uint256) {
        return _sent[sender].length;
    }

    function getSent(address sender, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] storage ids = _sent[sender];
        if (offset >= ids.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = ids[i];
        }
        return result;
    }
}
