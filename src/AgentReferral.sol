// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentReferral} from "./interfaces/IAgentReferral.sol";

/// @notice On-chain referral system for agent networks. 10% of referred agent fees flow to referrer forever.
contract AgentReferral is Ownable, ReentrancyGuard, Pausable, IAgentReferral {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_REFERRAL_BPS = 2000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_CYCLE_CHECK_DEPTH = 10;

    IERC20 public immutable paymentToken;
    uint256 public referralBps;

    mapping(address => address) private _referrer;
    mapping(address => address[]) private _referrees;
    mapping(address => bool) private _registered;
    mapping(address => bool) private _authorizedProtocol;

    mapping(address => uint256) private _pendingEth;
    mapping(address => uint256) private _pendingUsdc;
    mapping(address => uint256) private _totalFeesGenerated;
    mapping(address => uint256) private _claimedEth;
    mapping(address => uint256) private _claimedUsdc;

    constructor(
        IERC20 paymentToken_,
        address owner_,
        uint256 referralBps_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (referralBps_ > MAX_REFERRAL_BPS) revert ReferralBpsTooHigh(referralBps_);
        paymentToken = paymentToken_;
        referralBps = referralBps_;
    }

    // ─── Register Referral ──────────────────────────────────────────────

    function registerReferral(address referrer) external whenNotPaused {
        if (referrer == address(0)) revert ZeroAddress();
        if (referrer == msg.sender) revert SelfReferral();
        if (_registered[msg.sender]) revert AlreadyRegistered(msg.sender);

        address current = referrer;
        for (uint256 i; i < MAX_CYCLE_CHECK_DEPTH; i++) {
            current = _referrer[current];
            if (current == address(0)) break;
            if (current == msg.sender) revert CircularReferral(msg.sender, referrer);
        }

        _registered[msg.sender] = true;
        _referrer[msg.sender] = referrer;
        _referrees[referrer].push(msg.sender);

        emit ReferralRegistered(msg.sender, referrer);
    }

    // ─── Record Fee ─────────────────────────────────────────────────────

    function recordFee(
        address agent,
        uint256 feeAmount,
        address feeToken
    ) external payable nonReentrant {
        if (!_authorizedProtocol[msg.sender]) revert NotAuthorizedProtocol(msg.sender);

        address ref = _referrer[agent];
        if (ref == address(0)) {
            if (msg.value > 0) {
                (bool ok,) = msg.sender.call{value: msg.value}("");
                require(ok, "ETH refund failed");
            }
            return;
        }

        if (feeToken != address(0) && feeToken != address(paymentToken)) {
            revert InvalidFeeToken(feeToken);
        }

        uint256 reward = feeAmount.mulDiv(referralBps, BPS, Math.Rounding.Floor);
        if (reward == 0) return;

        _totalFeesGenerated[ref] += feeAmount;

        if (feeToken == address(0)) {
            if (msg.value < reward) revert InsufficientEthForReward(reward, msg.value);
            _pendingEth[ref] += reward;
            uint256 excess = msg.value - reward;
            if (excess > 0) {
                (bool ok,) = msg.sender.call{value: excess}("");
                require(ok, "ETH refund failed");
            }
        } else {
            if (msg.value > 0) revert UnexpectedEth();
            _pendingUsdc[ref] += reward;
            paymentToken.safeTransferFrom(msg.sender, address(this), reward);
        }

        emit FeeRecorded(agent, ref, feeAmount, reward, feeToken);
    }

    // ─── Claim Rewards ──────────────────────────────────────────────────

    function claimReferralRewards(address referrer) external nonReentrant {
        if (referrer == address(0)) revert ZeroAddress();
        uint256 ethAmt = _pendingEth[referrer];
        uint256 usdcAmt = _pendingUsdc[referrer];
        if (ethAmt == 0 && usdcAmt == 0) revert NoPendingRewards(referrer);

        _pendingEth[referrer] = 0;
        _pendingUsdc[referrer] = 0;
        _claimedEth[referrer] += ethAmt;
        _claimedUsdc[referrer] += usdcAmt;

        if (ethAmt > 0) {
            (bool ok,) = referrer.call{value: ethAmt}("");
            require(ok, "ETH transfer failed");
        }
        if (usdcAmt > 0) {
            paymentToken.safeTransfer(referrer, usdcAmt);
        }

        emit RewardsClaimed(referrer, ethAmt, usdcAmt);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function authorizeProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        _authorizedProtocol[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }

    function revokeProtocol(address protocol) external onlyOwner {
        _authorizedProtocol[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    function setReferralBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_REFERRAL_BPS) revert ReferralBpsTooHigh(newBps);
        uint256 old = referralBps;
        referralBps = newBps;
        emit ReferralBpsUpdated(old, newBps);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getReferrer(address agent) external view returns (address) {
        return _referrer[agent];
    }

    function getReferrees(address referrer) external view returns (address[] memory) {
        return _referrees[referrer];
    }

    function isRegistered(address agent) external view returns (bool) {
        return _registered[agent];
    }

    function isAuthorizedProtocol(address protocol) external view returns (bool) {
        return _authorizedProtocol[protocol];
    }

    function getPendingRewards(address referrer) external view returns (uint256 ethAmount, uint256 usdcAmount) {
        return (_pendingEth[referrer], _pendingUsdc[referrer]);
    }

    function getReferralStats(address referrer) external view returns (ReferralStats memory) {
        return ReferralStats({
            totalReferrees: _referrees[referrer].length,
            totalFeesGenerated: _totalFeesGenerated[referrer],
            totalEarnedEth: _claimedEth[referrer] + _pendingEth[referrer],
            totalEarnedUsdc: _claimedUsdc[referrer] + _pendingUsdc[referrer]
        });
    }
}
