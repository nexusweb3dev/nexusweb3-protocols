// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentSubscription} from "./interfaces/IAgentSubscription.sol";

/// @notice Recurring payment subscriptions between AI agents. Stripe for the agent economy.
contract AgentSubscription is Ownable, ReentrancyGuard, Pausable, IAgentSubscription {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_INTERVAL = 1 hours;
    uint256 public constant MAX_MONTHS = 12;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    address public treasury;
    uint256 public planCount;
    uint256 public subscriptionCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Plan) private _plans;
    mapping(uint256 => Subscription) private _subscriptions;

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

    // ─── Create Plan ────────────────────────────────────────────────────

    /// @notice Service provider creates a subscription plan.
    function createPlan(
        string calldata name,
        uint256 price,
        uint48 interval,
        uint256 maxSubscribers
    ) external whenNotPaused returns (uint256 planId) {
        if (bytes(name).length == 0) revert EmptyName();
        if (price == 0) revert InvalidPrice();
        if (interval < uint48(MIN_INTERVAL)) revert InvalidInterval();

        planId = planCount++;
        _plans[planId] = Plan({
            provider: msg.sender,
            name: name,
            price: price,
            interval: interval,
            maxSubscribers: maxSubscribers,
            subscriberCount: 0,
            active: true
        });

        emit PlanCreated(planId, msg.sender, name, price, interval);
    }

    // ─── Subscribe ──────────────────────────────────────────────────────

    /// @notice Subscribe to a plan. Pays upfront for N periods.
    function subscribe(uint256 planId, uint256 periods) external nonReentrant whenNotPaused returns (uint256 subscriptionId) {
        if (periods == 0 || periods > MAX_MONTHS) revert InvalidMonths();
        Plan storage p = _getPlan(planId);
        if (!p.active) revert PlanNotActive(planId);
        if (p.maxSubscribers > 0 && p.subscriberCount >= p.maxSubscribers) revert PlanFull(planId);

        uint256 total = p.price * periods;
        uint256 fee = total.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 providerPay = total - fee;

        uint48 now_ = uint48(block.timestamp);
        uint48 paidUntil = now_ + uint48(uint256(p.interval) * periods);

        subscriptionId = subscriptionCount++;
        _subscriptions[subscriptionId] = Subscription({
            subscriber: msg.sender,
            planId: planId,
            lockedPrice: p.price,
            nextPaymentDue: paidUntil,
            paidUntil: paidUntil,
            active: true
        });
        p.subscriberCount++;
        accumulatedFees += fee;

        paymentToken.safeTransferFrom(msg.sender, address(this), total);
        paymentToken.safeTransfer(p.provider, providerPay);

        emit Subscribed(subscriptionId, msg.sender, planId, paidUntil);
    }

    // ─── Renewal ────────────────────────────────────────────────────────

    /// @notice Process a due renewal. Keeper earns reward on success.
    function processRenewal(uint256 subscriptionId) external nonReentrant {
        Subscription storage s = _getSubscription(subscriptionId);
        if (!s.active) revert SubscriptionNotActive(subscriptionId);
        if (uint48(block.timestamp) < s.nextPaymentDue) {
            revert RenewalNotDue(subscriptionId, s.nextPaymentDue);
        }

        Plan storage p = _plans[s.planId];
        uint256 price = s.lockedPrice;
        uint256 fee = price.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 providerPay = price - fee;

        // try to charge subscriber — if fails, expire subscription
        try paymentToken.transferFrom(s.subscriber, address(this), price) {
            s.nextPaymentDue = uint48(block.timestamp) + p.interval;
            s.paidUntil = s.nextPaymentDue;
            accumulatedFees += fee;

            paymentToken.safeTransfer(p.provider, providerPay);
            emit RenewalProcessed(subscriptionId, msg.sender, price);
        } catch {
            s.active = false;
            p.subscriberCount--;
            emit SubscriptionExpired(subscriptionId);
        }
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    /// @notice Cancel subscription. No refund for current period.
    function cancelSubscription(uint256 subscriptionId) external {
        Subscription storage s = _getSubscription(subscriptionId);
        if (s.subscriber != msg.sender) revert NotSubscriber(subscriptionId);
        if (!s.active) revert SubscriptionNotActive(subscriptionId);

        s.active = false;
        _plans[s.planId].subscriberCount--;
        emit SubscriptionCancelled(subscriptionId);
    }

    // ─── Plan Management ────────────────────────────────────────────────

    function pausePlan(uint256 planId) external {
        Plan storage p = _getPlan(planId);
        if (p.provider != msg.sender) revert NotProvider(planId);
        p.active = false;
        emit PlanPaused(planId);
    }

    function resumePlan(uint256 planId) external {
        Plan storage p = _getPlan(planId);
        if (p.provider != msg.sender) revert NotProvider(planId);
        p.active = true;
        emit PlanResumed(planId);
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

    function isActive(uint256 subscriptionId) external view returns (bool) {
        if (subscriptionId >= subscriptionCount) return false;
        Subscription storage s = _subscriptions[subscriptionId];
        return s.active && s.paidUntil >= uint48(block.timestamp);
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        if (planId >= planCount) revert PlanNotFound(planId);
        return _plans[planId];
    }

    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory) {
        if (subscriptionId >= subscriptionCount) revert SubscriptionNotFound(subscriptionId);
        return _subscriptions[subscriptionId];
    }

    function _getPlan(uint256 planId) internal view returns (Plan storage) {
        if (planId >= planCount) revert PlanNotFound(planId);
        return _plans[planId];
    }

    function _getSubscription(uint256 subscriptionId) internal view returns (Subscription storage) {
        if (subscriptionId >= subscriptionCount) revert SubscriptionNotFound(subscriptionId);
        return _subscriptions[subscriptionId];
    }
}
