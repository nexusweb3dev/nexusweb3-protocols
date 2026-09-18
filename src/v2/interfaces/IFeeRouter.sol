// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFeeRouter
/// @notice Single sink for protocol fees (USDC). Protocols transfer the fee to the router, then call
///         `route(agent, amount)`. The router pays the agent's referrer (via the v1 AgentReferral
///         contract if configured), then splits the remainder between the staking pool and treasury.
interface IFeeRouter {
    struct Split {
        uint16 stakingBps; // share of post-referral fee to stakingRecipient
        uint16 treasuryBps; // share of post-referral fee to treasury; stakingBps + treasuryBps == 10_000
    }

    event FeeRouted(
        address indexed protocol,
        address indexed agent,
        uint256 amount,
        uint256 referral,
        uint256 staking,
        uint256 treasury
    );
    event SplitUpdated(uint16 stakingBps, uint16 treasuryBps);
    event RecipientsUpdated(address indexed treasury, address indexed stakingRecipient);
    event ReferralUpdated(address indexed referral);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    error NotAuthorizedProtocol(address caller);
    error AlreadyAuthorized(address protocol);
    error NotAuthorized(address protocol);
    error InvalidSplit();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Distribute `amount` of paymentToken already held by the router, attributed to `agent`.
    function route(address agent, uint256 amount) external;

    function paymentToken() external view returns (address);
    function treasury() external view returns (address);
    function stakingRecipient() external view returns (address);
    function referral() external view returns (address);
    function split() external view returns (uint16 stakingBps, uint16 treasuryBps);
    function isAuthorizedProtocol(address protocol) external view returns (bool);

    function setSplit(uint16 stakingBps, uint16 treasuryBps) external;
    function setRecipients(address treasury, address stakingRecipient) external;
    function setReferral(address referral) external;
    function authorizeProtocol(address protocol) external;
    function revokeProtocol(address protocol) external;
}
