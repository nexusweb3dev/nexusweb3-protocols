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

    function isOperatorFor(address agent, address caller) external view returns (bool) {
        if (caller == agent) return true;
        return _expiry[agent][caller] > block.timestamp;
    }

    function operatorExpiry(address agent, address operator) external view returns (uint48) {
        return _expiry[agent][operator];
    }
}
