// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentScheduler {
    struct Task {
        address owner;
        bytes taskData;
        uint48 executeAfter;
        uint48 repeatInterval;
        uint256 maxExecutions;
        uint256 executionCount;
        uint256 keeperBalance;
        bool active;
    }

    event TaskScheduled(uint256 indexed taskId, address indexed owner, uint48 executeAfter, uint48 repeatInterval);
    event TaskExecuted(uint256 indexed taskId, address indexed keeper, uint256 executionCount);
    event TaskCancelled(uint256 indexed taskId, address indexed owner, uint256 refund);
    event SchedulingFeeUpdated(uint256 oldFee, uint256 newFee);
    event KeeperRewardUpdated(uint256 oldReward, uint256 newReward);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error TaskNotFound(uint256 taskId);
    error TaskNotActive(uint256 taskId);
    error TaskNotReady(uint256 taskId, uint48 executeAfter);
    error TaskMaxExecutions(uint256 taskId);
    error NotTaskOwner(uint256 taskId);
    error InsufficientFee(uint256 required, uint256 provided);
    error MaxTasksPerOwner(address owner);
    error InvalidExecuteAfter();
    error InvalidMaxExecutions();
    error EmptyTaskData();
    error ZeroAddress();
    error NoFeesToCollect();
}
