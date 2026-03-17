// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentMessaging {
    struct Message {
        address sender;
        address recipient;
        bytes32 subject;
        bytes content;
        uint48 sentAt;
        uint48 readAt;
        uint256 replyToId;
        bool deleted;
    }

    event MessageSent(uint256 indexed messageId, address indexed sender, address indexed recipient, bytes32 subject);
    event MessageRead(uint256 indexed messageId, uint48 readAt);
    event MessageDeleted(uint256 indexed messageId);
    event MessageFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error InvalidRecipient();
    error ContentTooLarge(uint256 size, uint256 max);
    error EmptyContent();
    error MessageNotFound(uint256 messageId);
    error NotRecipient(uint256 messageId);
    error NotSender(uint256 messageId);
    error AlreadyRead(uint256 messageId);
    error AlreadyDeleted(uint256 messageId);
    error InvalidReplyTarget(uint256 messageId);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
    error InvalidPagination();
}
