// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentInsurance {
    struct Member {
        uint48 joinedAt;
        uint48 coverageEnd;
        uint256 premiumPaid;
        uint256 maxCoverage;
        uint256 claimedAmount;
        bool active;
        bool hasPendingClaim;
    }

    event MemberJoined(address indexed agent, uint256 premiumPaid, uint256 maxCoverage, uint48 coverageEnd);
    event PremiumRenewed(address indexed agent, uint256 premiumPaid, uint48 newCoverageEnd);
    event MemberLeft(address indexed agent);
    event ClaimSubmitted(address indexed agent, uint256 amount);
    event ClaimApproved(address indexed agent, uint256 amount);
    event ClaimRejected(address indexed agent);
    event PlatformFeeCollected(uint256 feeAmount, address indexed treasury);
    event MonthlyPremiumUpdated(uint256 oldPremium, uint256 newPremium);
    event CoverageMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error AlreadyMember(address agent);
    error NotMember(address agent);
    error CoverageExpired(address agent);
    error LockPeriodActive(address agent, uint48 unlockTime);
    error InvalidMonths();
    error ClaimTooLarge(uint256 requested, uint256 remaining);
    error InsufficientPoolBalance(uint256 requested, uint256 available);
    error NoPendingClaim(address agent);
    error ClaimAlreadyPending(address agent);
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint256 bps);

    function joinPool(uint256 months) external;
    function renewPremium(uint256 months) external;
    function leavePool() external;
    function claimLoss(uint256 amount) external;
    function verifyAndPay(address agent) external;
    function rejectClaim(address agent) external;
    function getMember(address agent) external view returns (Member memory);
    function isActiveMember(address agent) external view returns (bool);
    function poolBalance() external view returns (uint256);
    function monthlyPremium() external view returns (uint256);
    function coverageMultiplier() external view returns (uint256);
    function activeMemberCount() external view returns (uint256);
}
