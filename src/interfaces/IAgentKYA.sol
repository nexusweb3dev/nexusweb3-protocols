// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentKYA {
    enum KYAStatus { NONE, PENDING, VERIFIED, REVOKED, SUSPENDED }

    struct KYAData {
        string ownerName;
        string jurisdiction;
        string agentPurpose;
        uint256 maxSpendingLimit;
        bool humanSupervised;
        bytes32 documentHash;
        uint48 submittedAt;
        KYAStatus status;
        string revocationReason;
    }

    event KYASubmitted(address indexed agent, bytes32 documentHash, uint48 timestamp);
    event KYAVerified(address indexed agent, address indexed verifier, uint48 timestamp);
    event KYARevoked(address indexed agent, address indexed revokedBy, string reason);
    event KYASuspended(address indexed agent, address indexed suspendedBy);
    event VerifierAuthorized(address indexed verifier);
    event VerifierRevoked(address indexed verifier);
    event VerificationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error AlreadySubmitted(address agent);
    error NotSubmitted(address agent);
    error NotVerifier(address caller);
    error AlreadyVerifier(address verifier);
    error NotAuthorizedVerifier(address verifier);
    error InvalidDocumentHash();
    error EmptyOwnerName();
    error EmptyJurisdiction();
    error EmptyPurpose();
    error AlreadyVerified(address agent);
    error AlreadyRevoked(address agent);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
}
