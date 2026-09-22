// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentAccess
/// @notice Singleton operator registry. An agent principal (cold key or smart account that holds
///         funds and identity) authorizes hot "operator" keys to act on its behalf in every v2
///         contract. Operators never need to hold funds or identity.
interface IAgentAccess {
    event OperatorAuthorized(address indexed agent, address indexed operator, uint48 expiry);
    event OperatorRevoked(address indexed agent, address indexed operator);
    event OperatorRenounced(address indexed agent, address indexed operator);

    error ZeroAddress();
    error SelfOperator();
    error ExpiryInPast(uint48 expiry);
    error NotOperator(address agent, address operator);

    /// @notice Authorize `operator` to act for `msg.sender` until `expiry` (unix seconds).
    ///         Use type(uint48).max for no expiry. Re-authorizing updates the expiry.
    function authorizeOperator(address operator, uint48 expiry) external;

    /// @notice Revoke an operator immediately.
    function revokeOperator(address operator) external;

    /// @notice An operator gives up its own authorization for `agent` (e.g. after a suspected leak).
    function renounceOperator(address agent) external;

    /// @notice True if `caller` is `agent` itself or a currently valid operator for `agent`.
    function isOperatorFor(address agent, address caller) external view returns (bool);

    /// @notice Expiry timestamp of an operator authorization (0 = not authorized).
    function operatorExpiry(address agent, address operator) external view returns (uint48);
}
