// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentIdentityV2
/// @notice Free, non-expiring agent identity keyed by principal address, with an optional link to
///         a canonical ERC-8004 Identity Registry agentId (ERC-721) owned by the same principal.
interface IAgentIdentityV2 {
    struct AgentProfile {
        string name; // unique, 1..64 bytes
        string agentURI; // metadata JSON (endpoints, capabilities), 0..512 bytes
        uint8 agentType; // 0..10, free-form category
        uint48 registeredAt;
        uint48 updatedAt;
        bool active;
    }

    event AgentRegistered(address indexed agent, string name, uint8 agentType, string agentURI);
    event AgentURIUpdated(address indexed agent, string agentURI);
    event AgentTypeUpdated(address indexed agent, uint8 agentType);
    event AgentDeactivated(address indexed agent);
    event AgentReactivated(address indexed agent);
    event ERC8004Linked(address indexed agent, uint256 indexed agentId);
    event ERC8004Unlinked(address indexed agent, uint256 indexed agentId);
    event ERC8004RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    error EmptyName();
    error NameTooLong();
    /// @notice A name byte fell outside `[a-z0-9-_.]` (uppercase, whitespace, control or non-ASCII).
    error InvalidName();
    error URITooLong();
    error InvalidAgentType(uint8 agentType);
    error AlreadyRegistered(address agent);
    error NotRegistered(address agent);
    error AlreadyActive(address agent);
    error NameTaken(bytes32 nameHash);
    error ERC8004NotConfigured();
    error NotERC8004Owner(uint256 agentId, address owner);
    error InvalidERC8004Id();
    error ERC8004AlreadyLinked(uint256 agentId);
    error NotLinked(address agent);
    error ZeroAddress();

    // ─── Write (agent principal or operator) ────────────────────────────
    /// @notice Register `agent`. `name` is 1..64 bytes restricted to `[a-z0-9-_.]`: the charset is
    ///         what keeps two visually identical handles from being two distinct registrations.
    function register(address agent, string calldata name, string calldata agentURI, uint8 agentType) external;
    function setAgentURI(address agent, string calldata agentURI) external;
    function setAgentType(address agent, uint8 agentType) external;
    function deactivate(address agent) external;
    function reactivate(address agent) external;
    /// @notice Link an ERC-8004 agentId. Requires a non-zero `agentId` and
    ///         IERC721(erc8004Registry).ownerOf(agentId) == agent.
    function linkERC8004(address agent, uint256 agentId) external;
    function unlinkERC8004(address agent) external;

    // ─── Views (free) ───────────────────────────────────────────────────
    function getAgent(address agent) external view returns (AgentProfile memory);
    function isRegistered(address agent) external view returns (bool);
    function getAgentByName(string calldata name) external view returns (address);
    /// @notice 0 when unlinked, or when the link predates the current `registryEpoch`.
    function erc8004IdOf(address agent) external view returns (uint256);
    /// @notice address(0) when unlinked, or when the link predates the current `registryEpoch`.
    function agentOfERC8004(uint256 agentId) external view returns (address);
    function agentCount() external view returns (uint256);
    function erc8004Registry() external view returns (address);
    /// @notice Bumped on every `setERC8004Registry`; links from earlier epochs read as absent.
    function registryEpoch() external view returns (uint32);
}
