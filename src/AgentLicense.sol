// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentLicense} from "./interfaces/IAgentLicense.sol";

/// @notice On-chain IP licensing for AI agent outputs. Register, license, collect royalties.
contract AgentLicense is Ownable, ReentrancyGuard, Pausable, IAgentLicense {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant PERPETUAL_MULTIPLIER = 10;
    uint256 public constant MONTH = 30 days;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public licenseCount;
    uint256 public accumulatedFees;

    mapping(uint256 => License) private _licenses;
    mapping(uint256 => mapping(address => Licensee)) private _licensees;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
    }

    // ─── Register ───────────────────────────────────────────────────────

    /// @notice Register IP with licensing terms.
    function registerLicense(
        string calldata name,
        bytes32 contentHash,
        uint256 pricePerUse,
        uint256 subscriptionPrice
    ) external whenNotPaused returns (uint256 licenseId) {
        if (bytes(name).length == 0) revert EmptyName();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (pricePerUse == 0) revert InvalidPrice();

        licenseId = licenseCount++;
        _licenses[licenseId] = License({
            ipOwner: msg.sender,
            name: name,
            contentHash: contentHash,
            pricePerUse: pricePerUse,
            subscriptionPrice: subscriptionPrice,
            totalRoyalties: 0,
            claimedRoyalties: 0,
            totalUses: 0,
            active: true
        });

        emit LicenseRegistered(licenseId, msg.sender, name, contentHash);
    }

    // ─── Purchase ───────────────────────────────────────────────────────

    /// @notice Purchase a license. Type determines terms.
    function purchaseLicense(uint256 licenseId, uint8 licenseType) external nonReentrant whenNotPaused {
        License storage l = _getLicense(licenseId);
        if (!l.active) revert LicenseNotActive(licenseId);
        if (licenseType > uint8(LicenseType.PERPETUAL)) revert InvalidLicenseType(licenseType);

        Licensee storage buyer = _licensees[licenseId][msg.sender];
        uint256 price;

        if (LicenseType(licenseType) == LicenseType.PER_USE) {
            price = l.pricePerUse;
            buyer.usesRemaining += 1;
        } else if (LicenseType(licenseType) == LicenseType.SUBSCRIPTION) {
            if (l.subscriptionPrice == 0) revert InvalidPrice();
            price = l.subscriptionPrice;
            uint48 now_ = uint48(block.timestamp);
            uint48 base = buyer.subscriptionEnd > now_ ? buyer.subscriptionEnd : now_;
            buyer.subscriptionEnd = base + uint48(MONTH);
        } else {
            if (buyer.hasPerpetual) revert AlreadyHasPerpetual(licenseId, msg.sender);
            price = l.pricePerUse * PERPETUAL_MULTIPLIER;
            buyer.hasPerpetual = true;
        }

        uint256 fee = price.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 royalty = price - fee;

        l.totalRoyalties += royalty;
        accumulatedFees += fee;

        paymentToken.safeTransferFrom(msg.sender, address(this), price);

        emit LicensePurchased(licenseId, msg.sender, licenseType, price);
    }

    // ─── Usage ──────────────────────────────────────────────────────────

    /// @notice Record a use of licensed IP. Decrements per-use counter.
    function recordUsage(uint256 licenseId) external {
        if (licenseId >= licenseCount) revert LicenseNotFound(licenseId);
        Licensee storage buyer = _licensees[licenseId][msg.sender];

        // check any valid license type
        bool valid = buyer.hasPerpetual
            || buyer.subscriptionEnd >= uint48(block.timestamp)
            || buyer.usesRemaining > 0;

        if (!valid) revert NoValidLicense(licenseId, msg.sender);

        // decrement per-use if that's what they're using
        if (!buyer.hasPerpetual && buyer.subscriptionEnd < uint48(block.timestamp)) {
            if (buyer.usesRemaining == 0) revert NoUsesRemaining(licenseId, msg.sender);
            buyer.usesRemaining--;
        }

        _licenses[licenseId].totalUses++;
        emit UsageRecorded(licenseId, msg.sender);
    }

    // ─── Verify ─────────────────────────────────────────────────────────

    /// @notice Check if an agent has a valid license.
    function verifyLicense(uint256 licenseId, address agent) external view returns (bool) {
        if (licenseId >= licenseCount) return false;
        Licensee storage buyer = _licensees[licenseId][agent];
        return buyer.hasPerpetual
            || buyer.subscriptionEnd >= uint48(block.timestamp)
            || buyer.usesRemaining > 0;
    }

    // ─── Royalties ──────────────────────────────────────────────────────

    /// @notice Pull accumulated royalties to IP owner.
    function transferRoyalties(uint256 licenseId) external nonReentrant {
        License storage l = _getLicense(licenseId);
        uint256 unclaimed = l.totalRoyalties - l.claimedRoyalties;
        if (unclaimed == 0) revert NoRoyaltiesToClaim(licenseId);

        l.claimedRoyalties = l.totalRoyalties;
        paymentToken.safeTransfer(l.ipOwner, unclaimed);

        emit RoyaltiesTransferred(licenseId, l.ipOwner, unclaimed);
    }

    // ─── Deactivate ─────────────────────────────────────────────────────

    /// @notice IP owner deactivates a license. No new purchases.
    function deactivateLicense(uint256 licenseId) external {
        License storage l = _getLicense(licenseId);
        if (l.ipOwner != msg.sender) revert NotIPOwner(licenseId);
        l.active = false;
        emit LicenseDeactivated(licenseId);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        paymentToken.safeTransfer(treasury, amount);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
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

    function getLicense(uint256 licenseId) external view returns (License memory) {
        if (licenseId >= licenseCount) revert LicenseNotFound(licenseId);
        return _licenses[licenseId];
    }

    function getLicensee(uint256 licenseId, address agent) external view returns (Licensee memory) {
        return _licensees[licenseId][agent];
    }

    function getRoyalties(uint256 licenseId) external view returns (uint256) {
        if (licenseId >= licenseCount) revert LicenseNotFound(licenseId);
        License storage l = _licenses[licenseId];
        return l.totalRoyalties - l.claimedRoyalties;
    }

    function _getLicense(uint256 licenseId) internal view returns (License storage) {
        if (licenseId >= licenseCount) revert LicenseNotFound(licenseId);
        return _licenses[licenseId];
    }
}
