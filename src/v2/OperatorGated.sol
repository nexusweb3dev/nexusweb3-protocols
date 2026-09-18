// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentAccess} from "./interfaces/IAgentAccess.sol";

/// @title OperatorGated
/// @notice Mixin for v2 contracts. Every user-facing function takes the agent principal as an
///         explicit parameter and is callable by the principal or one of its operators.
abstract contract OperatorGated {
    IAgentAccess public immutable access;

    error NotAgentOrOperator(address agent, address caller);
    error ZeroAccess();

    constructor(IAgentAccess access_) {
        if (address(access_) == address(0)) revert ZeroAccess();
        access = access_;
    }

    modifier onlyAgentOrOperator(address agent) {
        _requireAgentOrOperator(agent);
        _;
    }

    function _requireAgentOrOperator(address agent) internal view {
        if (!access.isOperatorFor(agent, msg.sender)) revert NotAgentOrOperator(agent, msg.sender);
    }
}
