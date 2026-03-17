// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentKillSwitch {
    struct AgentConfig {
        address agentOwner;
        uint256 spendingLimit;
        uint256 spendingUsed;
        uint256 txLimit;
        uint256 txCount;
        uint48 sessionStart;
        uint48 sessionDuration;
        bool active;
        bool paused;
    }

    struct KillEvent {
        uint48 timestamp;
        address killedBy;
    }

    event AgentRegistered(address indexed agent, address indexed agentOwner, uint256 spendingLimit, uint256 txLimit);
    event AgentKilled(address indexed agent, address indexed killedBy, uint48 timestamp);
    event AgentPaused(address indexed agent, address indexed pausedBy);
    event AgentResumed(address indexed agent, address indexed resumedBy);
    event SessionReset(address indexed agent);
    event EmergencyMultisigUpdated(address indexed agent, address indexed oldMultisig, address indexed newMultisig);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error AgentAlreadyRegistered(address agent);
    error AgentNotRegistered(address agent);
    error AgentNotActive(address agent);
    error AgentIsPaused(address agent);
    error AgentIsKilled(address agent);
    error NotAgentOwner(address agent, address caller);
    error NotOwnerOrMultisig(address agent, address caller);
    error AgentCannotKillItself(address agent);
    error SessionExpired(address agent);
    error SpendingLimitExceeded(address agent, uint256 requested, uint256 remaining);
    error TxLimitExceeded(address agent);
    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidConfig();
    error ZeroAddress();
    error NoFeesToCollect();
    error NotAuthorizedProtocol(address caller);

    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);
}
