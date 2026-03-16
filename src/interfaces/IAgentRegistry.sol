// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentRegistry {
    struct AgentProfile {
        string name;
        string endpoint;
        uint8 agentType;
        uint48 registeredAt;
        uint48 expiresAt;
        bool active;
    }

    event AgentRegistered(address indexed agent, string name, uint8 agentType);
    event AgentRenewed(address indexed agent, uint48 newExpiry);
    event AgentEndpointUpdated(address indexed agent, string newEndpoint);
    event AgentDeactivated(address indexed agent);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event RenewalFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error AlreadyRegistered(address agent);
    error NotRegistered(address agent);
    error NameTaken(bytes32 nameHash);
    error EmptyName();
    error EmptyEndpoint();
    error InvalidAgentType(uint8 agentType);
    error ZeroAddress();

    function registerAgent(string calldata name, string calldata endpoint, uint8 agentType) external;
    function renewRegistration() external;
    function updateEndpoint(string calldata newEndpoint) external;
    function deactivateAgent() external;
    function getAgent(address agent) external view returns (AgentProfile memory);
    function isRegistered(address agent) external view returns (bool);
    function getAgentByName(string calldata name) external view returns (address);
    function registrationFee() external view returns (uint256);
    function renewalFee() external view returns (uint256);
    function treasury() external view returns (address);
    function agentCount() external view returns (uint256);
}
