// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentSplit} from "./interfaces/IAgentSplit.sol";

/// @notice Revenue splitting for AI agent teams. Payment in, automatic split out.
contract AgentSplit is Ownable, ReentrancyGuard, Pausable, IAgentSplit {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant TOTAL_SHARES = 10_000;
    uint256 public constant MAX_RECIPIENTS = 50;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    uint256 public creationFee;
    address public treasury;
    uint256 public splitCount;
    uint256 public accumulatedEthFees;
    uint256 public accumulatedUsdcFees;

    mapping(uint256 => Split) private _splits;
    mapping(address => uint256) private _claimable;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_,
        uint256 creationFee_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        creationFee = creationFee_;
    }

    // ─── Create ─────────────────────────────────────────────────────────

    /// @notice Create a revenue split with recipients and share allocations.
    function createSplit(
        address[] calldata recipients,
        uint256[] calldata shares,
        string calldata description
    ) external payable nonReentrant whenNotPaused returns (uint256 splitId) {
        if (bytes(description).length == 0) revert EmptyDescription();
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients(recipients.length);
        if (recipients.length != shares.length) revert InvalidShares();
        if (msg.value < creationFee) revert InsufficientFee(creationFee, msg.value);

        _validateShares(recipients, shares);

        splitId = splitCount++;
        Split storage s = _splits[splitId];
        s.splitOwner = msg.sender;
        s.description = description;
        s.totalReceived = 0;
        s.active = true;

        for (uint256 i; i < recipients.length; i++) {
            s.recipients.push(recipients[i]);
            s.shares.push(shares[i]);
        }

        accumulatedEthFees += msg.value;
        emit SplitCreated(splitId, msg.sender, recipients.length);
    }

    // ─── Receive & Distribute ───────────────────────────────────────────

    /// @notice Send USDC payment to a split. Distributes to all recipients minus platform fee.
    function receivePayment(uint256 splitId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        Split storage s = _getSplit(splitId);
        if (!s.active) revert SplitNotActive(splitId);

        // pull USDC from sender
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        // platform fee
        uint256 fee = amount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 distributable = amount - fee;
        if (fee > 0) {
            accumulatedUsdcFees += fee;
        }

        s.totalReceived += amount;

        // distribute to recipients
        for (uint256 i; i < s.recipients.length; i++) {
            uint256 payout = distributable * s.shares[i] / TOTAL_SHARES;
            if (payout > 0) {
                try this.safeDistribute(s.recipients[i], payout) {} catch {
                    _claimable[s.recipients[i]] += payout;
                    emit ClaimableStored(s.recipients[i], payout);
                }
            }
        }

        emit PaymentSplit(splitId, amount, fee);
    }

    /// @notice External helper for try/catch distribution.
    function safeDistribute(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal only");
        paymentToken.safeTransfer(to, amount);
    }

    // ─── Update Shares ──────────────────────────────────────────────────

    /// @notice Rebalance all shares at once.
    function updateShares(
        uint256 splitId,
        address[] calldata recipients,
        uint256[] calldata shares
    ) external {
        Split storage s = _getSplit(splitId);
        if (s.splitOwner != msg.sender) revert NotSplitOwner(splitId);
        if (!s.active) revert SplitNotActive(splitId);
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients(recipients.length);
        if (recipients.length != shares.length) revert InvalidShares();

        _validateShares(recipients, shares);

        // clear and rebuild
        delete s.recipients;
        delete s.shares;
        for (uint256 i; i < recipients.length; i++) {
            s.recipients.push(recipients[i]);
            s.shares.push(shares[i]);
        }

        emit SharesUpdated(splitId);
    }

    // ─── Deactivate ─────────────────────────────────────────────────────

    /// @notice Deactivate a split. No more payments accepted.
    function deactivateSplit(uint256 splitId) external {
        Split storage s = _getSplit(splitId);
        if (s.splitOwner != msg.sender) revert NotSplitOwner(splitId);
        s.active = false;
        emit SplitDeactivated(splitId);
    }

    // ─── Claim Failed Distribution ──────────────────────────────────────

    /// @notice Claim USDC from a failed distribution.
    function claimFailed() external nonReentrant {
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);
        emit ClaimableWithdrawn(msg.sender, amount);
    }

    function getClaimable(address addr) external view returns (uint256) {
        return _claimable[addr];
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 ethAmt = accumulatedEthFees;
        uint256 usdcAmt = accumulatedUsdcFees;
        if (ethAmt == 0 && usdcAmt == 0) revert NoFeesToCollect();

        accumulatedEthFees = 0;
        accumulatedUsdcFees = 0;

        if (ethAmt > 0) {
            (bool ok,) = treasury.call{value: ethAmt}("");
            require(ok, "ETH transfer failed");
        }
        if (usdcAmt > 0) {
            paymentToken.safeTransfer(treasury, usdcAmt);
        }
        emit FeesCollected(ethAmt + usdcAmt, treasury);
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

    function getSplit(uint256 splitId) external view returns (Split memory) {
        if (splitId >= splitCount) revert SplitNotFound(splitId);
        return _splits[splitId];
    }

    function getRecipients(uint256 splitId) external view returns (address[] memory, uint256[] memory) {
        Split storage s = _getSplit(splitId);
        return (s.recipients, s.shares);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _getSplit(uint256 splitId) internal view returns (Split storage) {
        if (splitId >= splitCount) revert SplitNotFound(splitId);
        return _splits[splitId];
    }

    function _validateShares(address[] calldata recipients, uint256[] calldata shares) internal pure {
        uint256 total;
        for (uint256 i; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (shares[i] == 0) revert InvalidShares();
            // check duplicates
            for (uint256 j; j < i; j++) {
                if (recipients[j] == recipients[i]) revert DuplicateRecipient(recipients[i]);
            }
            total += shares[i];
        }
        if (total != TOTAL_SHARES) revert InvalidShares();
    }
}
