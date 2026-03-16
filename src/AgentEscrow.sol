// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentEscrow} from "./interfaces/IAgentEscrow.sol";

/// @notice Trustless payment escrow for AI agent-to-agent transactions with 0.5% platform fee.
contract AgentEscrow is Ownable, ReentrancyGuard, Pausable, IAgentEscrow {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000; // 10% hard cap
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_DEADLINE_DURATION = 1 hours;
    uint256 public constant MAX_DEADLINE_DURATION = 90 days;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public escrowCount;

    mapping(uint256 => Escrow) private _escrows;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 feeBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);

        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = feeBps_;
    }

    // ─── Create ─────────────────────────────────────────────────────────

    function createEscrow(
        address recipient,
        uint256 amount,
        uint48 deadline
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        uint48 now_ = uint48(block.timestamp);
        if (deadline < now_ + uint48(MIN_DEADLINE_DURATION)) revert InvalidDeadline();
        if (deadline > now_ + uint48(MAX_DEADLINE_DURATION)) revert InvalidDeadline();

        escrowId = escrowCount++;
        _escrows[escrowId] = Escrow({
            depositor: msg.sender,
            recipient: recipient,
            amount: amount,
            deadline: deadline,
            createdAt: now_,
            status: EscrowStatus.Active
        });

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit EscrowCreated(escrowId, msg.sender, recipient, amount, deadline);
    }

    // ─── Release (recipient confirms delivery) ──────────────────────────

    function releasePayment(uint256 escrowId) external nonReentrant {
        Escrow storage e = _getEscrow(escrowId);
        if (e.status != EscrowStatus.Active) {
            revert WrongStatus(escrowId, e.status, EscrowStatus.Active);
        }
        // depositor or recipient can release
        if (msg.sender != e.depositor && msg.sender != e.recipient) {
            revert NotDepositor(escrowId);
        }

        e.status = EscrowStatus.Released;

        uint256 fee = _calculateFee(e.amount);
        uint256 payout = e.amount - fee;

        if (fee > 0) {
            paymentToken.safeTransfer(treasury, fee);
        }
        paymentToken.safeTransfer(e.recipient, payout);

        emit PaymentReleased(escrowId, e.recipient, payout, fee);
    }

    // ─── Refund (after deadline) ────────────────────────────────────────

    function refundEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = _getEscrow(escrowId);
        if (e.status != EscrowStatus.Active) {
            revert WrongStatus(escrowId, e.status, EscrowStatus.Active);
        }
        if (uint48(block.timestamp) < e.deadline) {
            revert DeadlineNotReached(escrowId, e.deadline);
        }

        e.status = EscrowStatus.Refunded;

        paymentToken.safeTransfer(e.depositor, e.amount);
        emit EscrowRefunded(escrowId, e.depositor, e.amount);
    }

    // ─── Dispute ────────────────────────────────────────────────────────

    function disputeEscrow(uint256 escrowId) external {
        Escrow storage e = _getEscrow(escrowId);
        if (e.status != EscrowStatus.Active) {
            revert WrongStatus(escrowId, e.status, EscrowStatus.Active);
        }
        if (msg.sender != e.depositor && msg.sender != e.recipient) {
            revert NotDepositor(escrowId);
        }

        e.status = EscrowStatus.Disputed;
        emit EscrowDisputed(escrowId, msg.sender);
    }

    function resolveDispute(uint256 escrowId, bool releaseToRecipient) external onlyOwner nonReentrant {
        Escrow storage e = _getEscrow(escrowId);
        if (e.status != EscrowStatus.Disputed) {
            revert WrongStatus(escrowId, e.status, EscrowStatus.Disputed);
        }

        e.status = EscrowStatus.Resolved;

        if (releaseToRecipient) {
            uint256 fee = _calculateFee(e.amount);
            uint256 payout = e.amount - fee;
            if (fee > 0) {
                paymentToken.safeTransfer(treasury, fee);
            }
            paymentToken.safeTransfer(e.recipient, payout);
            emit DisputeResolved(escrowId, e.recipient, payout, fee);
        } else {
            paymentToken.safeTransfer(e.depositor, e.amount);
            emit DisputeResolved(escrowId, e.depositor, e.amount, 0);
        }
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View ───────────────────────────────────────────────────────────

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        if (escrowId >= escrowCount) revert EscrowNotFound(escrowId);
        return _escrows[escrowId];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getEscrow(uint256 escrowId) internal view returns (Escrow storage) {
        if (escrowId >= escrowCount) revert EscrowNotFound(escrowId);
        return _escrows[escrowId];
    }

    function _calculateFee(uint256 amount) internal view returns (uint256) {
        if (platformFeeBps == 0) return 0;
        return amount.mulDiv(platformFeeBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    }
}
