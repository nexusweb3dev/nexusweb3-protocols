// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentEscrow {
    enum EscrowStatus {
        Active,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    struct Escrow {
        address depositor;
        address recipient;
        uint256 amount;
        uint48 deadline;
        uint48 createdAt;
        EscrowStatus status;
    }

    event EscrowCreated(uint256 indexed escrowId, address indexed depositor, address indexed recipient, uint256 amount, uint48 deadline);
    event PaymentReleased(uint256 indexed escrowId, address indexed recipient, uint256 amount, uint256 fee);
    event EscrowRefunded(uint256 indexed escrowId, address indexed depositor, uint256 amount);
    event EscrowDisputed(uint256 indexed escrowId, address indexed depositor);
    event DisputeResolved(uint256 indexed escrowId, address indexed winner, uint256 amount, uint256 fee);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error InvalidRecipient();
    error InvalidAmount();
    error InvalidDeadline();
    error EscrowNotFound(uint256 escrowId);
    error NotDepositor(uint256 escrowId);
    error NotRecipient(uint256 escrowId);
    error WrongStatus(uint256 escrowId, EscrowStatus current, EscrowStatus expected);
    error DeadlineNotReached(uint256 escrowId, uint48 deadline);
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);

    function createEscrow(address recipient, uint256 amount, uint48 deadline) external returns (uint256 escrowId);
    function releasePayment(uint256 escrowId) external;
    function refundEscrow(uint256 escrowId) external;
    function disputeEscrow(uint256 escrowId) external;
    function resolveDispute(uint256 escrowId, bool releaseToRecipient) external;
    function getEscrow(uint256 escrowId) external view returns (Escrow memory);
    function escrowCount() external view returns (uint256);
    function platformFeeBps() external view returns (uint256);
    function treasury() external view returns (address);
}
