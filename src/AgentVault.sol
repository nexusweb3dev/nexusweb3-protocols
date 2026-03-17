// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentVault} from "./interfaces/IAgentVault.sol";

/// @notice ERC-4626 vault with operator permissions for AI agents and a protocol fee on deposits.
contract AgentVault is ERC4626, Ownable, ReentrancyGuard, Pausable, IAgentVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 500; // 5% hard cap
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public protocolFeeBps;
    address public feeRecipient;
    mapping(address => OperatorConfig) private _operators;
    mapping(address => bool) private _isOperator;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address feeRecipient_,
        uint256 feeBps_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);

        feeRecipient = feeRecipient_;
        protocolFeeBps = feeBps_;
    }

    // ─── Operator Management ────────────────────────────────────────────

    function addOperator(address operator, uint128 spendingLimit) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (_isOperator[operator]) revert OperatorAlreadyExists(operator);

        _isOperator[operator] = true;
        _operators[operator] = OperatorConfig({spendingLimit: spendingLimit, spent: 0});
        emit OperatorAdded(operator, spendingLimit);
    }

    function removeOperator(address operator) external onlyOwner {
        if (!_isOperator[operator]) revert OperatorDoesNotExist(operator);

        _isOperator[operator] = false;
        delete _operators[operator];
        emit OperatorRemoved(operator);
    }

    function setSpendingLimit(address operator, uint128 newLimit) external onlyOwner {
        if (!_isOperator[operator]) revert OperatorDoesNotExist(operator);

        _operators[operator].spendingLimit = newLimit;
        emit OperatorSpendingLimitUpdated(operator, newLimit);
    }

    function resetOperatorSpent(address operator) external onlyOwner {
        if (!_isOperator[operator]) revert OperatorDoesNotExist(operator);

        _operators[operator].spent = 0;
        emit OperatorSpentReset(operator);
    }

    // ─── Operator Withdraw ──────────────────────────────────────────────

    function operatorWithdraw(uint256 assets, address to) external nonReentrant whenNotPaused {
        if (!_isOperator[msg.sender]) revert NotOperator(msg.sender);
        if (assets == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        OperatorConfig storage config = _operators[msg.sender];
        uint256 remaining = config.spendingLimit - config.spent;
        if (assets > remaining) revert SpendingLimitExceeded(msg.sender, assets, remaining);

        // safe: spending limit is uint128, so spent + assets <= 2*uint128.max fits uint128
        // since remaining = limit - spent >= assets, spent + assets <= limit <= uint128.max
        config.spent += uint128(assets);

        IERC20(asset()).safeTransfer(to, assets);
        emit OperatorWithdrawal(msg.sender, to, assets);
    }

    // ─── Fee Configuration ──────────────────────────────────────────────

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    function setProtocolFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);

        uint256 old = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeBpsUpdated(old, newBps);
    }

    // ─── Pausable ───────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View Functions ─────────────────────────────────────────────────

    function getOperatorConfig(address operator) external view returns (OperatorConfig memory) {
        return _operators[operator];
    }

    function isOperator(address account) external view returns (bool) {
        return _isOperator[account];
    }

    // ─── ERC4626 Overrides (fee on deposit) ─────────────────────────────

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        uint256 fee = _calculateFee(assets);
        if (fee > 0) {
            IERC20(asset()).safeTransferFrom(caller, feeRecipient, fee);
            emit ProtocolFeeCollected(caller, fee);
        }

        super._deposit(caller, receiver, assets - fee, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        // no whenNotPaused — users must always be able to exit
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function previewDeposit(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 fee = _calculateFee(assets);
        return super.previewDeposit(assets - fee);
    }

    function previewMint(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 assetsNeeded = super.previewMint(shares);
        return assetsNeeded.mulDiv(BPS_DENOMINATOR, BPS_DENOMINATOR - protocolFeeBps, Math.Rounding.Ceil);
    }

    // ─── Sweep (recover stuck tokens) ───────────────────────────────────

    function sweep(address token) external onlyOwner {
        if (token == asset()) revert CannotSweepVaultAsset();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(owner(), balance);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _calculateFee(uint256 assets) internal view returns (uint256) {
        if (protocolFeeBps == 0) return 0;
        return assets.mulDiv(protocolFeeBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    }
}
