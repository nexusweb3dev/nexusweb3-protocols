// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentMilestone} from "./interfaces/IAgentMilestone.sol";

/// @notice Milestone-based payment for multi-step agent tasks. Sequential delivery, auto-verify, auto-pay.
contract AgentMilestone is Ownable, ReentrancyGuard, Pausable, IAgentMilestone {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_MILESTONES = 20;
    uint256 public constant MIN_DEADLINE_OFFSET = 1 hours;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public contractCount;
    uint256 public accumulatedFees;

    mapping(uint256 => MilestoneContract) private _contracts;
    mapping(uint256 => Milestone[]) private _milestones;
    mapping(address => uint256) private _claimable;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
    }

    // ─── Create ─────────────────────────────────────────────────────────

    /// @notice Create a milestone-based payment contract.
    function createContract(
        address agent,
        uint256 totalAmount,
        bytes32[] calldata milestoneHashes,
        uint256[] calldata milestoneAmounts,
        uint48 deadline
    ) external nonReentrant whenNotPaused returns (uint256 contractId) {
        if (agent == address(0) || agent == msg.sender) revert ZeroAddress();
        if (totalAmount == 0) revert InvalidAmount();
        if (milestoneHashes.length == 0) revert EmptyMilestones();
        if (milestoneHashes.length > MAX_MILESTONES) revert TooManyMilestones(milestoneHashes.length);
        if (milestoneHashes.length != milestoneAmounts.length) revert EmptyMilestones();
        if (deadline < uint48(block.timestamp) + uint48(MIN_DEADLINE_OFFSET)) revert InvalidDeadline();

        // verify amounts sum to total
        uint256 sum;
        for (uint256 i; i < milestoneAmounts.length; i++) {
            sum += milestoneAmounts[i];
        }
        if (sum != totalAmount) revert AmountMismatch(sum, totalAmount);

        uint256 fee = totalAmount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);

        contractId = contractCount++;
        MilestoneContract storage c = _contracts[contractId];
        c.client = msg.sender;
        c.agent = agent;
        c.totalAmount = totalAmount;
        c.released = 0;
        c.deadline = deadline;
        c.active = true;
        c.milestoneCount = milestoneHashes.length;
        c.nextMilestone = 0;

        for (uint256 i; i < milestoneHashes.length; i++) {
            _milestones[contractId].push(Milestone({
                deliverableHash: milestoneHashes[i],
                amount: milestoneAmounts[i],
                status: MilestoneStatus.Pending
            }));
        }

        accumulatedFees += fee;
        paymentToken.safeTransferFrom(msg.sender, address(this), totalAmount + fee);

        emit ContractCreated(contractId, msg.sender, agent, totalAmount);
    }

    // ─── Submit Milestone ───────────────────────────────────────────────

    /// @notice Agent submits a milestone. Auto-pays if hash matches.
    function submitMilestone(
        uint256 contractId,
        uint256 milestoneIndex,
        bytes32 deliverableHash
    ) external nonReentrant {
        MilestoneContract storage c = _getContract(contractId);
        if (!c.active) revert ContractNotActive(contractId);
        if (msg.sender != c.agent) revert NotAgent(contractId);
        if (uint48(block.timestamp) > c.deadline) revert ContractExpiredError(contractId);

        // enforce sequential order
        if (milestoneIndex != c.nextMilestone) {
            revert MilestoneOutOfOrder(contractId, milestoneIndex, c.nextMilestone);
        }

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (m.status != MilestoneStatus.Pending) revert MilestoneNotPending(contractId, milestoneIndex);

        m.status = MilestoneStatus.Submitted;
        emit MilestoneSubmitted(contractId, milestoneIndex, deliverableHash);

        // auto-validate: hash match = instant pay
        if (deliverableHash == m.deliverableHash) {
            _releaseMilestone(contractId, c, m, milestoneIndex);
        }
    }

    // ─── Manual Approve ─────────────────────────────────────────────────

    /// @notice Client approves a submitted milestone.
    function approveMilestone(uint256 contractId, uint256 milestoneIndex) external nonReentrant {
        MilestoneContract storage c = _getContract(contractId);
        if (!c.active) revert ContractNotActive(contractId);
        if (msg.sender != c.client) revert NotClient(contractId);

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (m.status != MilestoneStatus.Submitted) revert MilestoneNotSubmitted(contractId, milestoneIndex);

        _releaseMilestone(contractId, c, m, milestoneIndex);
    }

    // ─── Dispute ────────────────────────────────────────────────────────

    /// @notice Client disputes a submitted milestone.
    function disputeMilestone(uint256 contractId, uint256 milestoneIndex) external {
        MilestoneContract storage c = _getContract(contractId);
        if (msg.sender != c.client) revert NotClient(contractId);

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (m.status != MilestoneStatus.Submitted) revert MilestoneNotSubmitted(contractId, milestoneIndex);

        m.status = MilestoneStatus.Disputed;
        emit MilestoneDisputed(contractId, milestoneIndex);
    }

    /// @notice Owner resolves dispute.
    function resolveDispute(uint256 contractId, uint256 milestoneIndex, bool approve) external onlyOwner nonReentrant {
        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (m.status != MilestoneStatus.Disputed) revert MilestoneNotSubmitted(contractId, milestoneIndex);

        MilestoneContract storage c = _contracts[contractId];

        if (approve) {
            _releaseMilestone(contractId, c, m, milestoneIndex);
        } else {
            m.status = MilestoneStatus.Pending;
            c.nextMilestone = milestoneIndex; // allow re-submission
        }
        emit DisputeResolved(contractId, milestoneIndex, approve);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    /// @notice Cancel contract. Only if no milestones delivered.
    function cancelContract(uint256 contractId) external nonReentrant {
        MilestoneContract storage c = _getContract(contractId);
        if (msg.sender != c.client) revert NotClient(contractId);
        if (!c.active) revert ContractNotActive(contractId);
        if (c.released > 0) revert MilestonesAlreadyDelivered(contractId);

        c.active = false;
        paymentToken.safeTransfer(c.client, c.totalAmount);

        emit ContractCancelled(contractId, c.totalAmount);
    }

    // ─── Expire ─────────────────────────────────────────────────────────

    /// @notice Expire contract. Refund undelivered milestones to client.
    function expireContract(uint256 contractId) external nonReentrant {
        MilestoneContract storage c = _getContract(contractId);
        if (!c.active) revert ContractNotActive(contractId);
        if (uint48(block.timestamp) <= c.deadline) revert InvalidDeadline();

        c.active = false;
        uint256 remaining = c.totalAmount - c.released;

        if (remaining > 0) {
            paymentToken.safeTransfer(c.client, remaining);
        }

        emit ContractExpired(contractId, remaining);
    }

    // ─── Claim ──────────────────────────────────────────────────────────

    function claimFunds() external nonReentrant {
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);
    }

    function getClaimable(address addr) external view returns (uint256) {
        return _claimable[addr];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        paymentToken.safeTransfer(treasury, amount);
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

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getContract(uint256 contractId) external view returns (MilestoneContract memory) {
        if (contractId >= contractCount) revert ContractNotFound(contractId);
        return _contracts[contractId];
    }

    function getMilestone(uint256 contractId, uint256 index) external view returns (Milestone memory) {
        if (contractId >= contractCount) revert ContractNotFound(contractId);
        return _milestones[contractId][index];
    }

    function getMilestones(uint256 contractId) external view returns (Milestone[] memory) {
        return _milestones[contractId];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getContract(uint256 contractId) internal view returns (MilestoneContract storage) {
        if (contractId >= contractCount) revert ContractNotFound(contractId);
        return _contracts[contractId];
    }

    function _releaseMilestone(
        uint256 contractId,
        MilestoneContract storage c,
        Milestone storage m,
        uint256 milestoneIndex
    ) internal {
        m.status = MilestoneStatus.Approved;
        c.released += m.amount;
        c.nextMilestone = milestoneIndex + 1;

        // deactivate if all milestones done
        if (c.nextMilestone >= c.milestoneCount) {
            c.active = false;
        }

        // pay agent — try/catch for safety
        try this._safePay(c.agent, m.amount) {} catch {
            _claimable[c.agent] += m.amount;
        }

        emit MilestoneApproved(contractId, milestoneIndex, m.amount);
    }

    function _safePay(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal only");
        paymentToken.safeTransfer(to, amount);
    }
}
