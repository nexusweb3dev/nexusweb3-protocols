// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentKYA} from "./interfaces/IAgentKYA.sol";

/// @notice On-chain KYA (Know Your Agent) compliance registry. Submit, verify, revoke agent identity.
contract AgentKYA is Ownable, ReentrancyGuard, Pausable, IAgentKYA {
    using SafeERC20 for IERC20;

    IERC20 public immutable paymentToken;

    uint256 public verificationFee;
    address public treasury;
    uint256 public accumulatedFees;
    uint256 public totalSubmissions;

    mapping(address => KYAData) private _kyaRecords;
    mapping(address => bool) private _submitted;
    mapping(address => bool) private _verifiers;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 verificationFee_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        treasury = treasury_;
        verificationFee = verificationFee_;
    }

    // ─── Submit KYA ─────────────────────────────────────────────────────

    /// @notice Submit KYA data for verification. Pays verification fee.
    function submitKYA(
        string calldata ownerName,
        string calldata jurisdiction,
        string calldata agentPurpose,
        uint256 maxSpendingLimit,
        bool humanSupervised,
        bytes32 documentHash
    ) external nonReentrant whenNotPaused {
        if (_submitted[msg.sender]) revert AlreadySubmitted(msg.sender);
        if (bytes(ownerName).length == 0) revert EmptyOwnerName();
        if (bytes(jurisdiction).length == 0) revert EmptyJurisdiction();
        if (bytes(agentPurpose).length == 0) revert EmptyPurpose();
        if (documentHash == bytes32(0)) revert InvalidDocumentHash();

        _kyaRecords[msg.sender] = KYAData({
            ownerName: ownerName,
            jurisdiction: jurisdiction,
            agentPurpose: agentPurpose,
            maxSpendingLimit: maxSpendingLimit,
            humanSupervised: humanSupervised,
            documentHash: documentHash,
            submittedAt: uint48(block.timestamp),
            status: KYAStatus.PENDING,
            revocationReason: ""
        });
        _submitted[msg.sender] = true;
        totalSubmissions++;
        accumulatedFees += verificationFee;

        paymentToken.safeTransferFrom(msg.sender, address(this), verificationFee);

        emit KYASubmitted(msg.sender, documentHash, uint48(block.timestamp));
    }

    // ─── Verify / Revoke / Suspend ──────────────────────────────────────

    /// @notice Approve a pending KYA submission. Only authorized verifiers.
    function approveKYA(address agent) external {
        if (!_verifiers[msg.sender]) revert NotVerifier(msg.sender);
        if (!_submitted[agent]) revert NotSubmitted(agent);
        KYAData storage d = _kyaRecords[agent];
        if (d.status == KYAStatus.VERIFIED) revert AlreadyVerified(agent);
        if (d.status == KYAStatus.REVOKED) revert AlreadyRevoked(agent);

        d.status = KYAStatus.VERIFIED;
        emit KYAVerified(agent, msg.sender, uint48(block.timestamp));
    }

    /// @notice Revoke a KYA with reason. Verifiers or contract owner.
    function revokeKYA(address agent, string calldata reason) external {
        if (!_verifiers[msg.sender] && msg.sender != owner()) revert NotVerifier(msg.sender);
        if (!_submitted[agent]) revert NotSubmitted(agent);
        KYAData storage d = _kyaRecords[agent];
        if (d.status == KYAStatus.REVOKED) revert AlreadyRevoked(agent);

        d.status = KYAStatus.REVOKED;
        d.revocationReason = reason;
        emit KYARevoked(agent, msg.sender, reason);
    }

    /// @notice Suspend a verified KYA temporarily.
    function suspendKYA(address agent) external {
        if (!_verifiers[msg.sender] && msg.sender != owner()) revert NotVerifier(msg.sender);
        if (!_submitted[agent]) revert NotSubmitted(agent);

        _kyaRecords[agent].status = KYAStatus.SUSPENDED;
        emit KYASuspended(agent, msg.sender);
    }

    // ─── Verifier Management ────────────────────────────────────────────

    function authorizeVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        if (_verifiers[verifier]) revert AlreadyVerifier(verifier);
        _verifiers[verifier] = true;
        emit VerifierAuthorized(verifier);
    }

    function revokeVerifier(address verifier) external onlyOwner {
        if (!_verifiers[verifier]) revert NotAuthorizedVerifier(verifier);
        _verifiers[verifier] = false;
        emit VerifierRevoked(verifier);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        paymentToken.safeTransfer(treasury, amount);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setVerificationFee(uint256 newFee) external onlyOwner {
        uint256 old = verificationFee;
        verificationFee = newFee;
        emit VerificationFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function isVerified(address agent) external view returns (bool) {
        return _submitted[agent] && _kyaRecords[agent].status == KYAStatus.VERIFIED;
    }

    function getKYAStatus(address agent) external view returns (KYAStatus status, uint48 submittedAt) {
        if (!_submitted[agent]) return (KYAStatus.NONE, 0);
        KYAData storage d = _kyaRecords[agent];
        return (d.status, d.submittedAt);
    }

    function getKYAData(address agent) external view returns (KYAData memory) {
        if (!_submitted[agent]) revert NotSubmitted(agent);
        return _kyaRecords[agent];
    }

    function isVerifier(address addr) external view returns (bool) {
        return _verifiers[addr];
    }
}
