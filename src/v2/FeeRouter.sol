// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";

/// @notice Minimal view of the v1 AgentReferral sink consumed by the router.
interface IReferralSink {
    function recordFee(address agent, uint256 feeAmount, address feeToken) external payable;
}

/// @title FeeRouter
/// @notice Single sink for protocol fees. Authorized protocols transfer the fee token to this
///         contract and call `route`. The router first offers the fee to the referral contract
///         (which pulls the referrer's share), then splits the remainder between the staking
///         recipient and the treasury. Treasury absorbs rounding dust.
contract FeeRouter is Ownable, ReentrancyGuard, IFeeRouter {
    using SafeERC20 for IERC20;
    /// @notice Basis-point denominator (100%).
    uint16 public constant BPS = 10_000;

    IERC20 private immutable _paymentToken;

    address private _treasury;
    address private _stakingRecipient;
    address private _referral;
    uint16 private _stakingBps;
    uint16 private _treasuryBps;

    mapping(address => bool) private _authorizedProtocol;

    /// @param paymentToken_ ERC20 the router distributes (USDC).
    /// @param owner_ Contract owner.
    /// @param treasury_ Receives the treasury share plus rounding dust.
    /// @param stakingRecipient_ Receives the staking share.
    /// @param referral_ v1 AgentReferral contract, or zero to disable referrals.
    /// @param stakingBps_ Staking share of the post-referral remainder.
    /// @param treasuryBps_ Treasury share; must sum with `stakingBps_` to 10_000.
    constructor(
        IERC20 paymentToken_,
        address owner_,
        address treasury_,
        address stakingRecipient_,
        address referral_,
        uint16 stakingBps_,
        uint16 treasuryBps_
    )
        Ownable(owner_)
    {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0) || stakingRecipient_ == address(0)) revert ZeroAddress();
        if (uint256(stakingBps_) + uint256(treasuryBps_) != BPS) revert InvalidSplit();

        _paymentToken = paymentToken_;
        _treasury = treasury_;
        _stakingRecipient = stakingRecipient_;
        _referral = referral_;
        _stakingBps = stakingBps_;
        _treasuryBps = treasuryBps_;

        if (referral_ != address(0)) {
            SafeERC20.forceApprove(paymentToken_, referral_, type(uint256).max);
        }
    }

    // ─── Routing ────────────────────────────────────────────────────────

    /// @inheritdoc IFeeRouter
    /// @dev A reverting or misbehaving referral contract must never block fee routing, so the
    ///      referral call is wrapped in try/catch and the amount it pulled is measured from the
    ///      router's own balance delta (clamped to `amount` so an over-pull cannot underflow).
    function route(address agent, uint256 amount) external nonReentrant {
        if (!_authorizedProtocol[msg.sender]) revert NotAuthorizedProtocol(msg.sender);
        if (amount == 0) revert ZeroAmount();

        IERC20 token = _paymentToken;
        uint256 balanceBefore = token.balanceOf(address(this));
        if (balanceBefore < amount) revert InsufficientBalance(amount, balanceBefore);

        uint256 referralPaid;
        address referral_ = _referral;
        if (referral_ != address(0)) {
            try IReferralSink(referral_).recordFee(agent, amount, address(token)) {} catch {}
            uint256 balanceAfter = token.balanceOf(address(this));
            referralPaid = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
            if (referralPaid > amount) referralPaid = amount;
        }

        uint256 remainder = amount - referralPaid;
        uint256 stakingShare = (remainder * _stakingBps) / BPS;
        uint256 treasuryShare = remainder - stakingShare;

        if (stakingShare > 0) token.safeTransfer(_stakingRecipient, stakingShare);
        if (treasuryShare > 0) token.safeTransfer(_treasury, treasuryShare);

        emit FeeRouted(msg.sender, agent, amount, referralPaid, stakingShare, treasuryShare);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeRouter
    function setSplit(uint16 stakingBps_, uint16 treasuryBps_) external onlyOwner {
        if (uint256(stakingBps_) + uint256(treasuryBps_) != BPS) revert InvalidSplit();
        _stakingBps = stakingBps_;
        _treasuryBps = treasuryBps_;
        emit SplitUpdated(stakingBps_, treasuryBps_);
    }

    /// @inheritdoc IFeeRouter
    function setRecipients(address treasury_, address stakingRecipient_) external onlyOwner {
        if (treasury_ == address(0) || stakingRecipient_ == address(0)) revert ZeroAddress();
        _treasury = treasury_;
        _stakingRecipient = stakingRecipient_;
        emit RecipientsUpdated(treasury_, stakingRecipient_);
    }

    /// @inheritdoc IFeeRouter
    /// @dev Pass the zero address to disable referral payouts. The outgoing referral contract's
    ///      allowance is always revoked before the new one is granted.
    function setReferral(address referral_) external onlyOwner {
        IERC20 token = _paymentToken;
        address previous = _referral;
        if (previous != address(0)) SafeERC20.forceApprove(token, previous, 0);

        _referral = referral_;
        if (referral_ != address(0)) SafeERC20.forceApprove(token, referral_, type(uint256).max);

        emit ReferralUpdated(referral_);
    }

    /// @inheritdoc IFeeRouter
    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        if (_authorizedProtocol[protocol]) revert AlreadyAuthorized(protocol);
        _authorizedProtocol[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    /// @inheritdoc IFeeRouter
    function revokeProtocol(address protocol) external onlyOwner {
        if (!_authorizedProtocol[protocol]) revert NotAuthorized(protocol);
        _authorizedProtocol[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeRouter
    function paymentToken() external view returns (address) {
        return address(_paymentToken);
    }

    /// @inheritdoc IFeeRouter
    function treasury() external view returns (address) {
        return _treasury;
    }

    /// @inheritdoc IFeeRouter
    function stakingRecipient() external view returns (address) {
        return _stakingRecipient;
    }

    /// @inheritdoc IFeeRouter
    function referral() external view returns (address) {
        return _referral;
    }

    /// @inheritdoc IFeeRouter
    function split() external view returns (uint16 stakingBps, uint16 treasuryBps) {
        return (_stakingBps, _treasuryBps);
    }

    /// @inheritdoc IFeeRouter
    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocol[protocol];
    }
}
