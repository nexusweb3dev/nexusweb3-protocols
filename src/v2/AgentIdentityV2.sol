// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {OperatorGated} from "./OperatorGated.sol";
import {IAgentAccess} from "./interfaces/IAgentAccess.sol";
import {IAgentIdentityV2} from "./interfaces/IAgentIdentityV2.sol";

/// @title AgentIdentityV2
/// @notice Free, non-expiring agent identity keyed by principal address. Every write takes the
///         agent principal explicitly and is callable by the principal or one of its operators.
///         Optionally links a canonical ERC-8004 Identity Registry agentId owned by the principal.
contract AgentIdentityV2 is OperatorGated, Ownable, Pausable, IAgentIdentityV2 {
    /// @notice Highest accepted `agentType` value.
    uint8 public constant MAX_AGENT_TYPE = 10;
    /// @notice Maximum `name` length in bytes.
    uint256 public constant MAX_NAME_LENGTH = 64;
    /// @notice Maximum `agentURI` length in bytes.
    uint256 public constant MAX_URI_LENGTH = 512;

    /// @inheritdoc IAgentIdentityV2
    address public erc8004Registry;
    /// @inheritdoc IAgentIdentityV2
    uint256 public agentCount;

    mapping(address agent => AgentProfile profile) private _agents;
    mapping(bytes32 nameHash => address agent) private _nameOwner;
    mapping(address agent => uint256 agentId) private _erc8004Id;
    mapping(uint256 agentId => address agent) private _erc8004Agent;

    /// @param access_ Singleton operator registry used to authorize operator calls.
    /// @param owner_ Owner allowed to pause and to set the ERC-8004 registry.
    /// @param erc8004Registry_ ERC-721 identity registry, or address(0) to leave linking disabled.
    constructor(IAgentAccess access_, address owner_, address erc8004Registry_) OperatorGated(access_) Ownable(owner_) {
        erc8004Registry = erc8004Registry_;
        emit ERC8004RegistryUpdated(address(0), erc8004Registry_);
    }

    // ─── Registration ───────────────────────────────────────────────────

    /// @notice Register a free, non-expiring profile for `agent`.
    /// @param agent Agent principal the profile belongs to.
    /// @param name Globally unique name, 1..64 bytes.
    /// @param agentURI Metadata URI, 0..512 bytes.
    /// @param agentType Free-form category, 0..10.
    function register(
        address agent,
        string calldata name,
        string calldata agentURI,
        uint8 agentType
    )
        external
        whenNotPaused
        onlyAgentOrOperator(agent)
    {
        uint256 nameLen = bytes(name).length;
        if (nameLen == 0) revert EmptyName();
        if (nameLen > MAX_NAME_LENGTH) revert NameTooLong();
        if (bytes(agentURI).length > MAX_URI_LENGTH) revert URITooLong();
        if (agentType > MAX_AGENT_TYPE) revert InvalidAgentType(agentType);
        if (_agents[agent].registeredAt != 0) revert AlreadyRegistered(agent);

        bytes32 nameHash = keccak256(abi.encode(name));
        if (_nameOwner[nameHash] != address(0)) revert NameTaken(nameHash);

        uint48 now_ = uint48(block.timestamp);
        _agents[agent] = AgentProfile({
            name: name, agentURI: agentURI, agentType: agentType, registeredAt: now_, updatedAt: now_, active: true
        });
        _nameOwner[nameHash] = agent;
        agentCount++;

        emit AgentRegistered(agent, name, agentType, agentURI);
    }

    /// @notice Replace the metadata URI of a registered agent.
    /// @param agent Agent principal whose profile is updated.
    /// @param agentURI New metadata URI, 0..512 bytes.
    function setAgentURI(address agent, string calldata agentURI) external whenNotPaused onlyAgentOrOperator(agent) {
        if (bytes(agentURI).length > MAX_URI_LENGTH) revert URITooLong();
        AgentProfile storage profile = _requireProfile(agent);
        profile.agentURI = agentURI;
        profile.updatedAt = uint48(block.timestamp);
        emit AgentURIUpdated(agent, agentURI);
    }

    /// @notice Replace the category of a registered agent.
    /// @param agent Agent principal whose profile is updated.
    /// @param agentType New category, 0..10.
    function setAgentType(address agent, uint8 agentType) external whenNotPaused onlyAgentOrOperator(agent) {
        if (agentType > MAX_AGENT_TYPE) revert InvalidAgentType(agentType);
        AgentProfile storage profile = _requireProfile(agent);
        profile.agentType = agentType;
        profile.updatedAt = uint48(block.timestamp);
        emit AgentTypeUpdated(agent, agentType);
    }

    /// @notice Deactivate an agent. Works while paused so agents can always exit.
    /// @dev The name stays reserved for `agent` and can be reclaimed by reactivating.
    /// @param agent Agent principal to deactivate.
    function deactivate(address agent) external onlyAgentOrOperator(agent) {
        AgentProfile storage profile = _agents[agent];
        if (!profile.active) revert NotRegistered(agent);
        profile.active = false;
        profile.updatedAt = uint48(block.timestamp);
        agentCount--;
        emit AgentDeactivated(agent);
    }

    /// @notice Reactivate a previously deactivated agent.
    /// @param agent Agent principal to reactivate.
    function reactivate(address agent) external whenNotPaused onlyAgentOrOperator(agent) {
        AgentProfile storage profile = _requireProfile(agent);
        if (profile.active) revert AlreadyActive(agent);
        profile.active = true;
        profile.updatedAt = uint48(block.timestamp);
        agentCount++;
        emit AgentReactivated(agent);
    }

    // ─── ERC-8004 link ──────────────────────────────────────────────────

    /// @notice Link the ERC-8004 `agentId` owned by `agent` to its profile.
    /// @dev Any existing link held by `agent` is unlinked first. A stale link left by a previous owner
    ///      of `agentId` is cleared automatically (ownership is re-verified against the registry).
    /// @param agent Agent principal that must own `agentId` in the ERC-8004 registry.
    /// @param agentId ERC-721 token id in the ERC-8004 identity registry.
    function linkERC8004(address agent, uint256 agentId) external whenNotPaused onlyAgentOrOperator(agent) {
        address registry = erc8004Registry;
        if (registry == address(0)) revert ERC8004NotConfigured();
        _requireProfile(agent);

        address holder = IERC721(registry).ownerOf(agentId);
        if (holder != agent) revert NotERC8004Owner(agentId, holder);

        // A previous linker that no longer owns the token holds a stale link: clear it instead of
        // letting a former owner squat the id forever. `holder == agent` already proves this.
        address linkedTo = _erc8004Agent[agentId];
        if (linkedTo != address(0) && linkedTo != agent) {
            delete _erc8004Id[linkedTo];
            delete _erc8004Agent[agentId];
            emit ERC8004Unlinked(linkedTo, agentId);
        }

        uint256 current = _erc8004Id[agent];
        if (current != 0 && current != agentId) {
            delete _erc8004Agent[current];
            emit ERC8004Unlinked(agent, current);
        }

        _erc8004Id[agent] = agentId;
        _erc8004Agent[agentId] = agent;
        emit ERC8004Linked(agent, agentId);
    }

    /// @notice Remove the ERC-8004 link of `agent`. Works while paused so agents can always exit.
    /// @param agent Agent principal whose link is removed.
    function unlinkERC8004(address agent) external onlyAgentOrOperator(agent) {
        uint256 agentId = _erc8004Id[agent];
        if (agentId == 0) revert NotLinked(agent);
        delete _erc8004Id[agent];
        delete _erc8004Agent[agentId];
        emit ERC8004Unlinked(agent, agentId);
    }

    // ─── Owner ──────────────────────────────────────────────────────────

    /// @notice Set the ERC-8004 identity registry. address(0) disables linking.
    /// @param registry New ERC-721 registry address.
    function setERC8004Registry(address registry) external onlyOwner {
        address old = erc8004Registry;
        erc8004Registry = registry;
        emit ERC8004RegistryUpdated(old, registry);
    }

    /// @notice Pause registration, profile updates, reactivation and linking.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lift the pause.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @notice Full profile of `agent`. Returns a zeroed struct if never registered.
    /// @param agent Agent principal to read.
    function getAgent(address agent) external view returns (AgentProfile memory) {
        return _agents[agent];
    }

    /// @notice True if `agent` has a profile and it is active.
    /// @param agent Agent principal to check.
    function isRegistered(address agent) external view returns (bool) {
        return _agents[agent].active;
    }

    /// @notice Owner of `name`, including deactivated agents. address(0) if unclaimed.
    /// @param name Name to resolve.
    function getAgentByName(string calldata name) external view returns (address) {
        return _nameOwner[keccak256(abi.encode(name))];
    }

    /// @notice ERC-8004 id linked to `agent`, or 0 when none.
    /// @param agent Agent principal to read.
    function erc8004IdOf(address agent) external view returns (uint256) {
        return _erc8004Id[agent];
    }

    /// @notice Agent that linked `agentId`, or address(0) when unlinked.
    /// @param agentId ERC-8004 token id to resolve.
    function agentOfERC8004(uint256 agentId) external view returns (address) {
        return _erc8004Agent[agentId];
    }

    /// @notice True if `agent` has a profile, whether active or deactivated.
    /// @param agent Agent principal to check.
    function exists(address agent) external view returns (bool) {
        return _agents[agent].registeredAt != 0;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _requireProfile(address agent) private view returns (AgentProfile storage profile) {
        profile = _agents[agent];
        if (profile.registeredAt == 0) revert NotRegistered(agent);
    }
}
