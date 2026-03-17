// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentInsolvency} from "./interfaces/IAgentInsolvency.sol";

/// @notice Debt and insolvency management for AI agent treasuries. Orderly wind-down with proportional claims.
contract AgentInsolvency is Ownable, ReentrancyGuard, Pausable, IAgentInsolvency {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DEBTS_PER_AGENT = 100;

    IERC20 public immutable paymentToken;

    uint256 public platformFeeBps;
    uint256 public immutable registrationFee;
    address public treasury;
    uint256 public debtCount;
    uint256 public accumulatedEthFees;
    uint256 public accumulatedUsdcFees;

    mapping(uint256 => Debt) private _debts;
    mapping(address => uint256[]) private _debtorDebts;
    mapping(address => bool) private _isInsolvent;
    mapping(address => uint256) private _insolvencyPool;
    mapping(address => uint256) private _totalConfirmedDebt;
    mapping(address => uint256) private _totalPaidOut;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 platformFeeBps_,
        uint256 registrationFee_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        paymentToken = paymentToken_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        registrationFee = registrationFee_;
    }

    // ─── Register Debt ──────────────────────────────────────────────────

    function registerDebt(
        address creditor,
        uint256 amount,
        uint48 dueDate,
        string calldata description
    ) external payable nonReentrant whenNotPaused returns (uint256 debtId) {
        if (creditor == address(0)) revert ZeroAddress();
        if (creditor == msg.sender) revert SelfDebt();
        if (amount == 0) revert InvalidAmount();
        if (dueDate <= uint48(block.timestamp)) revert InvalidDueDate();
        if (bytes(description).length == 0) revert EmptyDescription();
        if (msg.value < registrationFee) revert InsufficientFee(registrationFee, msg.value);
        if (_isInsolvent[msg.sender]) revert AlreadyInsolvent(msg.sender);
        if (_debtorDebts[msg.sender].length >= MAX_DEBTS_PER_AGENT) revert TooManyDebts(msg.sender);

        debtId = debtCount++;
        _debts[debtId] = Debt({
            debtor: msg.sender,
            creditor: creditor,
            originalAmount: amount,
            remainingAmount: amount,
            dueDate: dueDate,
            description: description,
            confirmed: false,
            resolved: false
        });
        _debtorDebts[msg.sender].push(debtId);
        accumulatedEthFees += msg.value;

        emit DebtRegistered(debtId, msg.sender, creditor, amount);
    }

    // ─── Confirm Debt ───────────────────────────────────────────────────

    function confirmDebt(uint256 debtId) external {
        Debt storage d = _getDebt(debtId);
        if (d.creditor != msg.sender) revert NotCreditor(debtId);
        if (d.confirmed) revert DebtAlreadyConfirmed(debtId);

        d.confirmed = true;
        emit DebtConfirmed(debtId, msg.sender);
    }

    // ─── Repay Debt ─────────────────────────────────────────────────────

    function repayDebt(uint256 debtId, uint256 amount) external nonReentrant {
        Debt storage d = _getDebt(debtId);
        if (d.debtor != msg.sender) revert NotDebtor(debtId);
        if (!d.confirmed) revert DebtNotConfirmed(debtId);
        if (d.resolved) revert DebtAlreadyResolved(debtId);
        if (amount == 0) revert InvalidAmount();
        if (amount > d.remainingAmount) revert RepaymentExceedsDebt(debtId, amount, d.remainingAmount);

        d.remainingAmount -= amount;
        if (d.remainingAmount == 0) {
            d.resolved = true;
        }

        uint256 fee = amount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
        uint256 creditorPay = amount - fee;
        accumulatedUsdcFees += fee;

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        paymentToken.safeTransfer(d.creditor, creditorPay);

        emit DebtRepaid(debtId, amount, d.remainingAmount);
    }

    // ─── Insolvency ─────────────────────────────────────────────────────

    function declareInsolvency(address agent, uint256 depositAmount) external nonReentrant {
        if (msg.sender != agent && msg.sender != owner()) revert NotDebtorOrOwner(agent, msg.sender);
        if (_isInsolvent[agent]) revert AlreadyInsolvent(agent);

        uint256[] storage debtIds = _debtorDebts[agent];
        uint256 totalDebt;
        for (uint256 i; i < debtIds.length; i++) {
            Debt storage d = _debts[debtIds[i]];
            if (d.confirmed && !d.resolved) {
                totalDebt += d.remainingAmount;
            }
        }

        _isInsolvent[agent] = true;
        _totalConfirmedDebt[agent] = totalDebt;

        if (depositAmount > 0) {
            uint256 fee = depositAmount.mulDiv(platformFeeBps, BPS, Math.Rounding.Floor);
            _insolvencyPool[agent] = depositAmount - fee;
            accumulatedUsdcFees += fee;
            paymentToken.safeTransferFrom(msg.sender, address(this), depositAmount);
        }

        emit InsolvencyDeclared(agent, totalDebt);
    }

    function claimInsolvencyPayout(address agent, uint256 debtId) external nonReentrant {
        if (!_isInsolvent[agent]) revert NotInsolvent(agent);

        Debt storage d = _getDebt(debtId);
        if (d.debtor != agent) revert NotDebtor(debtId);
        if (d.creditor != msg.sender) revert NotCreditor(debtId);
        if (!d.confirmed) revert DebtNotConfirmed(debtId);
        if (d.resolved) revert DebtAlreadyResolved(debtId);

        uint256 pool = _insolvencyPool[agent];
        if (pool == 0) revert NoAssetsToDistribute(agent);

        uint256 totalDebt = _totalConfirmedDebt[agent];
        uint256 payout = d.remainingAmount.mulDiv(pool, totalDebt, Math.Rounding.Floor);

        d.resolved = true;
        _totalPaidOut[agent] += payout;

        paymentToken.safeTransfer(msg.sender, payout);

        emit InsolvencyPayout(agent, msg.sender, payout);
    }

    function processInsolvencyPayout(address agent) external nonReentrant {
        if (!_isInsolvent[agent]) revert NotInsolvent(agent);

        uint256 pool = _insolvencyPool[agent];
        if (pool == 0) revert NoAssetsToDistribute(agent);

        uint256 totalDebt = _totalConfirmedDebt[agent];
        uint256[] storage debtIds = _debtorDebts[agent];

        uint256 count;
        address[] memory creditors = new address[](debtIds.length);
        uint256[] memory payouts = new uint256[](debtIds.length);

        for (uint256 i; i < debtIds.length; i++) {
            Debt storage d = _debts[debtIds[i]];
            if (d.confirmed && !d.resolved) {
                uint256 payout = d.remainingAmount.mulDiv(pool, totalDebt, Math.Rounding.Floor);
                d.resolved = true;
                creditors[count] = d.creditor;
                payouts[count] = payout;
                count++;
            }
        }

        if (count == 0) revert NoPendingClaims(agent);

        uint256 totalPaid;
        for (uint256 i; i < count; i++) {
            totalPaid += payouts[i];
            paymentToken.safeTransfer(creditors[i], payouts[i]);
            emit InsolvencyPayout(agent, creditors[i], payouts[i]);
        }

        _totalPaidOut[agent] += totalPaid;
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
        emit FeesCollected(ethAmt, usdcAmt, treasury);
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

    function getDebt(uint256 debtId) external view returns (Debt memory) {
        if (debtId >= debtCount) revert DebtNotFound(debtId);
        return _debts[debtId];
    }

    function isInsolvent(address agent) external view returns (bool) {
        return _isInsolvent[agent];
    }

    function getInsolvencyPool(address agent) external view returns (uint256) {
        return _insolvencyPool[agent];
    }

    function getTotalConfirmedDebt(address agent) external view returns (uint256) {
        return _totalConfirmedDebt[agent];
    }

    function getTotalPaidOut(address agent) external view returns (uint256) {
        return _totalPaidOut[agent];
    }

    function getDebtCount(address agent) external view returns (uint256) {
        return _debtorDebts[agent].length;
    }

    function getSolvencyStatus(address agent) external view returns (SolvencyStatus memory) {
        uint256[] storage debtIds = _debtorDebts[agent];
        uint256 totalDebts;
        for (uint256 i; i < debtIds.length; i++) {
            Debt storage d = _debts[debtIds[i]];
            if (d.confirmed && !d.resolved) {
                totalDebts += d.remainingAmount;
            }
        }

        uint256 poolBalance = _insolvencyPool[agent] > _totalPaidOut[agent]
            ? _insolvencyPool[agent] - _totalPaidOut[agent]
            : 0;

        return SolvencyStatus({
            totalDebts: totalDebts,
            poolBalance: poolBalance,
            isSolvent: !_isInsolvent[agent]
        });
    }

    function getDebts(address agent) external view returns (Debt[] memory) {
        uint256[] storage debtIds = _debtorDebts[agent];
        Debt[] memory result = new Debt[](debtIds.length);
        for (uint256 i; i < debtIds.length; i++) {
            result[i] = _debts[debtIds[i]];
        }
        return result;
    }

    function getCreditors(address agent) external view returns (address[] memory) {
        uint256[] storage debtIds = _debtorDebts[agent];
        address[] memory raw = new address[](debtIds.length);
        uint256 count;
        for (uint256 i; i < debtIds.length; i++) {
            Debt storage d = _debts[debtIds[i]];
            if (d.confirmed && !d.resolved) {
                bool duplicate;
                for (uint256 j; j < count; j++) {
                    if (raw[j] == d.creditor) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    raw[count++] = d.creditor;
                }
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i; i < count; i++) {
            result[i] = raw[i];
        }
        return result;
    }

    function _getDebt(uint256 debtId) internal view returns (Debt storage) {
        if (debtId >= debtCount) revert DebtNotFound(debtId);
        return _debts[debtId];
    }
}
