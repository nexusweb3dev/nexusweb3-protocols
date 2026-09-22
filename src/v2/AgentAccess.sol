// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentAccess} from "./interfaces/IAgentAccess.sol";

/// @title AgentAccess
/// @notice Permissionless singleton: agent principals delegate to operator keys with an expiry.
///         No owner, no fee, no pause. Every v2 contract reads this to accept operator calls.
contract AgentAccess is IAgentAccess {
    mapping(address agent => mapping(address operator => uint48 expiry)) private _expiry;

    function authorizeOperator(address operator, uint48 expiry) external {
        if (operator == address(0)) revert ZeroAddress();
        if (operator == msg.sender) revert SelfOperator();
        if (expiry <= block.timestamp) revert ExpiryInPast(expiry);
        _expiry[msg.sender][operator] = expiry;
        emit OperatorAuthorized(msg.sender, operator, expiry);
    }

    function revokeOperator(address operator) external {
        if (_expiry[msg.sender][operator] == 0) revert NotOperator(msg.sender, operator);
        delete _expiry[msg.sender][operator];
        emit OperatorRevoked(msg.sender, operator);
    }

    function renounceOperator(address agent) external {
        if (_expiry[agent][msg.sender] == 0) revert NotOperator(agent, msg.sender);
        delete _expiry[agent][msg.sender];
        emit OperatorRenounced(agent, msg.sender);
    }

    /// @notice True if `caller` is `agent` itself or a currently valid operator for `agent`.
    ///         This view is authoritative; `operatorExpiry` may return a stale (expired) timestamp.
    function isOperatorFor(address agent, address caller) external view returns (bool) {
        if (caller == agent) return true;
        return _expiry[agent][caller] > block.timestamp;
    }

    /// @notice Expiry of a live authorization, or 0 once it has lapsed or been revoked.
    function operatorExpiry(address agent, address operator) external view returns (uint48) {
        uint48 e = _expiry[agent][operator];
        return e > block.timestamp ? e : 0;
    }
}
