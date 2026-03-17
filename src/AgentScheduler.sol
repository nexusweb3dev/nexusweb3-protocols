// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentScheduler} from "./interfaces/IAgentScheduler.sol";

/// @notice On-chain task scheduler for AI agents. Keepers trigger execution and earn rewards.
contract AgentScheduler is Ownable, ReentrancyGuard, Pausable, IAgentScheduler {
    uint256 public constant MAX_TASKS_PER_OWNER = 100;
    uint256 public constant MIN_INTERVAL = 5 minutes;

    uint256 public schedulingFee;
    uint256 public keeperReward;
    address public treasury;
    uint256 public taskCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Task) private _tasks;
    mapping(address => uint256) private _ownerTaskCount;

    constructor(
        address treasury_,
        address owner_,
        uint256 schedulingFee_,
        uint256 keeperReward_
    ) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        schedulingFee = schedulingFee_;
        keeperReward = keeperReward_;
    }

    // ─── Schedule ───────────────────────────────────────────────────────

    /// @notice Register a task for future execution. Pays scheduling fee + keeper reward deposit.
    function scheduleTask(
        bytes calldata taskData,
        uint48 executeAfter,
        uint48 repeatInterval,
        uint256 maxExecutions
    ) external payable nonReentrant whenNotPaused returns (uint256 taskId) {
        if (taskData.length == 0) revert EmptyTaskData();
        if (executeAfter <= uint48(block.timestamp)) revert InvalidExecuteAfter();
        if (maxExecutions == 0) revert InvalidMaxExecutions();
        if (repeatInterval > 0 && repeatInterval < uint48(MIN_INTERVAL)) revert InvalidExecuteAfter();
        if (_ownerTaskCount[msg.sender] >= MAX_TASKS_PER_OWNER) revert MaxTasksPerOwner(msg.sender);

        uint256 totalKeeperDeposit = keeperReward * maxExecutions;
        uint256 requiredFee = schedulingFee + totalKeeperDeposit;
        if (msg.value < requiredFee) revert InsufficientFee(requiredFee, msg.value);

        taskId = taskCount++;
        _tasks[taskId] = Task({
            owner: msg.sender,
            taskData: taskData,
            executeAfter: executeAfter,
            repeatInterval: repeatInterval,
            maxExecutions: maxExecutions,
            executionCount: 0,
            keeperBalance: totalKeeperDeposit,
            active: true
        });
        _ownerTaskCount[msg.sender]++;
        accumulatedFees += schedulingFee;

        // refund overpayment
        uint256 excess = msg.value - requiredFee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "Refund failed");
        }

        emit TaskScheduled(taskId, msg.sender, executeAfter, repeatInterval);
    }

    // ─── Execute ────────────────────────────────────────────────────────

    /// @notice Execute a ready task. Caller earns keeper reward.
    function executeTask(uint256 taskId) external nonReentrant {
        Task storage t = _getTask(taskId);
        if (!t.active) revert TaskNotActive(taskId);
        if (uint48(block.timestamp) < t.executeAfter) revert TaskNotReady(taskId, t.executeAfter);
        if (t.executionCount >= t.maxExecutions) revert TaskMaxExecutions(taskId);

        t.executionCount++;

        // reschedule or deactivate
        if (t.repeatInterval > 0 && t.executionCount < t.maxExecutions) {
            t.executeAfter = uint48(block.timestamp) + t.repeatInterval;
        } else if (t.executionCount >= t.maxExecutions) {
            t.active = false;
            _ownerTaskCount[t.owner]--;
        }

        // pay keeper
        uint256 reward = 0;
        if (t.keeperBalance >= keeperReward) {
            reward = keeperReward;
            t.keeperBalance -= reward;
            (bool ok,) = msg.sender.call{value: reward}("");
            require(ok, "Keeper reward failed");
        }

        emit TaskExecuted(taskId, msg.sender, t.executionCount);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    /// @notice Cancel a task and refund unused keeper deposit.
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage t = _getTask(taskId);
        if (!t.active) revert TaskNotActive(taskId);
        if (t.owner != msg.sender) revert NotTaskOwner(taskId);

        t.active = false;
        _ownerTaskCount[msg.sender]--;

        uint256 refund = t.keeperBalance;
        t.keeperBalance = 0;

        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit TaskCancelled(taskId, msg.sender, refund);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect accumulated scheduling fees to treasury.
    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Fee transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setSchedulingFee(uint256 newFee) external onlyOwner {
        uint256 old = schedulingFee;
        schedulingFee = newFee;
        emit SchedulingFeeUpdated(old, newFee);
    }

    function setKeeperReward(uint256 newReward) external onlyOwner {
        uint256 old = keeperReward;
        keeperReward = newReward;
        emit KeeperRewardUpdated(old, newReward);
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

    function getTask(uint256 taskId) external view returns (Task memory) {
        if (taskId >= taskCount) revert TaskNotFound(taskId);
        return _tasks[taskId];
    }

    function getOwnerTaskCount(address owner) external view returns (uint256) {
        return _ownerTaskCount[owner];
    }

    function isTaskReady(uint256 taskId) external view returns (bool) {
        if (taskId >= taskCount) return false;
        Task storage t = _tasks[taskId];
        return t.active && uint48(block.timestamp) >= t.executeAfter && t.executionCount < t.maxExecutions;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getTask(uint256 taskId) internal view returns (Task storage) {
        if (taskId >= taskCount) revert TaskNotFound(taskId);
        return _tasks[taskId];
    }
}
