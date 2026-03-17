// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentStaking {
    struct StakeInfo {
        address owner;
        uint256 amount;
        uint256 weightedAmount;
        uint48 lockUntil;
        uint256 rewardDebt;
        bool active;
    }

    event Staked(uint256 indexed stakeId, address indexed owner, uint256 amount, uint256 lockDays, uint256 boost);
    event Unstaked(uint256 indexed stakeId, address indexed owner, uint256 amount, uint256 rewards);
    event RewardsClaimed(uint256 indexed stakeId, address indexed owner, uint256 amount);
    event RevenueDistributed(uint256 amount, uint256 totalWeightedStake);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error InvalidLockPeriod(uint256 lockDays);
    error StakeNotFound(uint256 stakeId);
    error NotStakeOwner(uint256 stakeId);
    error StakeNotActive(uint256 stakeId);
    error LockNotExpired(uint256 stakeId, uint48 lockUntil);
    error ZeroAmount();
    error ZeroAddress();
    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error NothingToClaim(uint256 stakeId);
    error NoRevenue();
}
