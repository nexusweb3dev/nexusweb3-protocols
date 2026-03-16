// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IAgentInsurance} from "./interfaces/IAgentInsurance.sol";

/// @notice Insurance pool for AI agents. Agents pay USDC premiums for loss coverage. 15% platform fee.
contract AgentInsurance is Ownable, ReentrancyGuard, Pausable, IAgentInsurance {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 5000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant LOCK_PERIOD = 30 days;
    uint256 public constant MAX_MONTHS = 12;
    uint256 public constant MONTH = 30 days;

    IERC20 public immutable paymentToken;
    IAavePool public immutable aavePool;
    IERC20 public immutable aToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public monthlyPremium;
    uint256 public coverageMultiplier;
    uint256 public activeMemberCount;
    uint256 public totalPremiumsCollected;
    uint256 public totalClaimsPaid;
    uint256 public pendingClaimsTotal;

    mapping(address => Member) private _members;
    mapping(address => uint256) private _pendingClaimAmount;

    constructor(
        IERC20 paymentToken_,
        IAavePool aavePool_,
        IERC20 aToken_,
        address treasury_,
        address owner_,
        uint256 monthlyPremium_,
        uint256 coverageMultiplier_,
        uint256 feeBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (address(aavePool_) == address(0)) revert ZeroAddress();
        if (address(aToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (monthlyPremium_ == 0) revert ZeroAmount();
        if (coverageMultiplier_ == 0) revert ZeroAmount();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);

        paymentToken = paymentToken_;
        aavePool = aavePool_;
        aToken = aToken_;
        treasury = treasury_;
        monthlyPremium = monthlyPremium_;
        coverageMultiplier = coverageMultiplier_;
        platformFeeBps = feeBps_;

        IERC20(paymentToken_).forceApprove(address(aavePool_), type(uint256).max);
    }

    // ─── Join Pool ──────────────────────────────────────────────────────

    function joinPool(uint256 months) external nonReentrant whenNotPaused {
        if (months == 0 || months > MAX_MONTHS) revert InvalidMonths();
        if (_members[msg.sender].active) revert AlreadyMember(msg.sender);

        uint256 totalPremium = monthlyPremium * months;
        uint256 fee = totalPremium.mulDiv(platformFeeBps, BPS_DENOMINATOR, Math.Rounding.Floor);
        uint256 poolAmount = totalPremium - fee;
        uint256 coverage = totalPremium * coverageMultiplier;

        uint48 now_ = uint48(block.timestamp);
        uint48 coverageEnd = now_ + uint48(months * MONTH);

        _members[msg.sender] = Member({
            joinedAt: now_,
            coverageEnd: coverageEnd,
            premiumPaid: totalPremium,
            maxCoverage: coverage,
            claimedAmount: 0,
            active: true,
            hasPendingClaim: false
        });
        activeMemberCount++;
        totalPremiumsCollected += totalPremium;

        // CEI: state updated above, transfers below
        paymentToken.safeTransferFrom(msg.sender, treasury, fee);
        paymentToken.safeTransferFrom(msg.sender, address(this), poolAmount);
        aavePool.supply(address(paymentToken), poolAmount, address(this), 0);

        emit MemberJoined(msg.sender, totalPremium, coverage, coverageEnd);
        emit PlatformFeeCollected(fee, treasury);
    }

    // ─── Renew ──────────────────────────────────────────────────────────

    function renewPremium(uint256 months) external nonReentrant whenNotPaused {
        if (months == 0 || months > MAX_MONTHS) revert InvalidMonths();
        Member storage m = _members[msg.sender];
        if (!m.active) revert NotMember(msg.sender);

        uint256 totalPremium = monthlyPremium * months;
        uint256 fee = totalPremium.mulDiv(platformFeeBps, BPS_DENOMINATOR, Math.Rounding.Floor);
        uint256 poolAmount = totalPremium - fee;
        uint256 additionalCoverage = totalPremium * coverageMultiplier;

        uint48 now_ = uint48(block.timestamp);
        uint48 base = m.coverageEnd < now_ ? now_ : m.coverageEnd;
        m.coverageEnd = base + uint48(months * MONTH);
        m.premiumPaid += totalPremium;
        m.maxCoverage += additionalCoverage;
        totalPremiumsCollected += totalPremium;

        paymentToken.safeTransferFrom(msg.sender, treasury, fee);
        paymentToken.safeTransferFrom(msg.sender, address(this), poolAmount);
        aavePool.supply(address(paymentToken), poolAmount, address(this), 0);

        emit PremiumRenewed(msg.sender, totalPremium, m.coverageEnd);
        emit PlatformFeeCollected(fee, treasury);
    }

    // ─── Leave Pool ─────────────────────────────────────────────────────

    function leavePool() external nonReentrant {
        Member storage m = _members[msg.sender];
        if (!m.active) revert NotMember(msg.sender);

        uint48 unlockTime = m.joinedAt + uint48(LOCK_PERIOD);
        if (uint48(block.timestamp) < unlockTime) {
            revert LockPeriodActive(msg.sender, unlockTime);
        }

        m.active = false;
        activeMemberCount--;

        emit MemberLeft(msg.sender);
    }

    // ─── Claims ─────────────────────────────────────────────────────────

    function claimLoss(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Member storage m = _members[msg.sender];
        if (!m.active) revert NotMember(msg.sender);
        if (m.coverageEnd < uint48(block.timestamp)) revert CoverageExpired(msg.sender);
        if (m.hasPendingClaim) revert ClaimAlreadyPending(msg.sender);

        uint48 unlockTime = m.joinedAt + uint48(LOCK_PERIOD);
        if (uint48(block.timestamp) < unlockTime) {
            revert LockPeriodActive(msg.sender, unlockTime);
        }

        uint256 remaining = m.maxCoverage - m.claimedAmount;
        if (amount > remaining) revert ClaimTooLarge(amount, remaining);

        m.hasPendingClaim = true;
        _pendingClaimAmount[msg.sender] = amount;
        pendingClaimsTotal += amount;

        emit ClaimSubmitted(msg.sender, amount);
    }

    function verifyAndPay(address agent) external onlyOwner nonReentrant {
        Member storage m = _members[agent];
        if (!m.hasPendingClaim) revert NoPendingClaim(agent);

        uint256 amount = _pendingClaimAmount[agent];
        uint256 available = poolBalance();
        if (amount > available) revert InsufficientPoolBalance(amount, available);

        m.hasPendingClaim = false;
        m.claimedAmount += amount;
        _pendingClaimAmount[agent] = 0;
        pendingClaimsTotal -= amount;
        totalClaimsPaid += amount;

        aavePool.withdraw(address(paymentToken), amount, agent);

        emit ClaimApproved(agent, amount);
    }

    function rejectClaim(address agent) external onlyOwner {
        Member storage m = _members[agent];
        if (!m.hasPendingClaim) revert NoPendingClaim(agent);

        uint256 amount = _pendingClaimAmount[agent];
        m.hasPendingClaim = false;
        _pendingClaimAmount[agent] = 0;
        pendingClaimsTotal -= amount;

        emit ClaimRejected(agent);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setMonthlyPremium(uint256 newPremium) external onlyOwner {
        if (newPremium == 0) revert ZeroAmount();
        uint256 old = monthlyPremium;
        monthlyPremium = newPremium;
        emit MonthlyPremiumUpdated(old, newPremium);
    }

    function setCoverageMultiplier(uint256 newMultiplier) external onlyOwner {
        if (newMultiplier == 0) revert ZeroAmount();
        uint256 old = coverageMultiplier;
        coverageMultiplier = newMultiplier;
        emit CoverageMultiplierUpdated(old, newMultiplier);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View ───────────────────────────────────────────────────────────

    function getMember(address agent) external view returns (Member memory) {
        return _members[agent];
    }

    function isActiveMember(address agent) external view returns (bool) {
        Member storage m = _members[agent];
        return m.active && m.coverageEnd > uint48(block.timestamp);
    }

    function poolBalance() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
