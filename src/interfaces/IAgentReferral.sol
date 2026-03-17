// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentReferral {
    struct ReferralStats {
        uint256 totalReferrees;
        uint256 totalFeesGenerated;
        uint256 totalEarnedEth;
        uint256 totalEarnedUsdc;
    }

    event ReferralRegistered(address indexed agent, address indexed referrer);
    event FeeRecorded(address indexed agent, address indexed referrer, uint256 feeAmount, uint256 reward, address feeToken);
    event RewardsClaimed(address indexed referrer, uint256 ethAmount, uint256 usdcAmount);
    event ProtocolAuthorized(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);
    event ReferralBpsUpdated(uint256 oldBps, uint256 newBps);

    error ZeroAddress();
    error SelfReferral();
    error AlreadyRegistered(address agent);
    error CircularReferral(address agent, address referrer);
    error NotAuthorizedProtocol(address caller);
    error NoPendingRewards(address referrer);
    error InvalidFeeToken(address token);
    error InsufficientEthForReward(uint256 required, uint256 sent);
    error ReferralBpsTooHigh(uint256 bps);
    error UnexpectedEth();

    event EthTransferFailed(address indexed referrer, uint256 amount);
}
