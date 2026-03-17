// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentStorage} from "./interfaces/IAgentStorage.sol";

/// @notice On-chain key-value storage for AI agents. Persistent, permanent, access controlled.
contract AgentStorage is Ownable, ReentrancyGuard, Pausable, IAgentStorage {
    uint256 public constant MAX_VALUE_SIZE = 1024;
    uint256 public constant MAX_KEYS_PER_OWNER = 1000;
    uint256 public constant REFUND_BPS = 5000; // 50% refund on delete

    uint256 public writeFee;
    address public treasury;
    uint256 public accumulatedFees;

    // owner => key => value
    mapping(address => mapping(bytes32 => bytes)) private _values;
    mapping(address => mapping(bytes32 => bool)) private _keyExists;
    mapping(address => uint256) private _keyCount;
    // owner => key => reader => allowed
    mapping(address => mapping(bytes32 => mapping(address => bool))) private _readAccess;

    constructor(address treasury_, address owner_, uint256 writeFee_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        writeFee = writeFee_;
    }

    // ─── Write ──────────────────────────────────────────────────────────

    /// @notice Store a value under a key. First writer owns the key for their address namespace.
    function setValue(bytes32 key, bytes calldata value) external payable nonReentrant whenNotPaused {
        if (value.length == 0) revert EmptyValue();
        if (value.length > MAX_VALUE_SIZE) revert ValueTooLarge(value.length, MAX_VALUE_SIZE);
        if (msg.value < writeFee) revert InsufficientFee(writeFee, msg.value);

        bool isNew = !_keyExists[msg.sender][key];
        if (isNew) {
            if (_keyCount[msg.sender] >= MAX_KEYS_PER_OWNER) revert MaxKeysReached(msg.sender);
            _keyExists[msg.sender][key] = true;
            _keyCount[msg.sender]++;
        }

        _values[msg.sender][key] = value;
        accumulatedFees += msg.value;

        emit ValueSet(msg.sender, key, value.length);
    }

    // ─── Read ───────────────────────────────────────────────────────────

    /// @notice Read a value. Owner can always read. Others need explicit access.
    function getValue(address keyOwner, bytes32 key) external view returns (bytes memory) {
        if (!_keyExists[keyOwner][key]) revert KeyNotFound(keyOwner, key);
        if (msg.sender != keyOwner && !_readAccess[keyOwner][key][msg.sender]) {
            revert NoReadAccess(msg.sender, keyOwner, key);
        }
        return _values[keyOwner][key];
    }

    /// @notice Read a value without access control (public data pattern).
    function getValuePublic(address keyOwner, bytes32 key) external view returns (bytes memory) {
        if (!_keyExists[keyOwner][key]) revert KeyNotFound(keyOwner, key);
        return _values[keyOwner][key];
    }

    // ─── Access Control ─────────────────────────────────────────────────

    /// @notice Grant read access to another address.
    function grantReadAccess(bytes32 key, address reader) external {
        if (!_keyExists[msg.sender][key]) revert KeyNotFound(msg.sender, key);
        if (reader == address(0)) revert ZeroAddress();
        _readAccess[msg.sender][key][reader] = true;
        emit ReadAccessGranted(msg.sender, key, reader);
    }

    /// @notice Revoke read access from another address.
    function revokeReadAccess(bytes32 key, address reader) external {
        if (!_keyExists[msg.sender][key]) revert KeyNotFound(msg.sender, key);
        _readAccess[msg.sender][key][reader] = false;
        emit ReadAccessRevoked(msg.sender, key, reader);
    }

    // ─── Delete ─────────────────────────────────────────────────────────

    /// @notice Delete a key-value pair. Returns 50% of write fee.
    function deleteValue(bytes32 key) external nonReentrant {
        if (!_keyExists[msg.sender][key]) revert KeyNotFound(msg.sender, key);

        _keyExists[msg.sender][key] = false;
        delete _values[msg.sender][key];
        _keyCount[msg.sender]--;

        uint256 refund = writeFee * REFUND_BPS / 10_000;
        if (refund > 0 && accumulatedFees >= refund) {
            accumulatedFees -= refund;
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit ValueDeleted(msg.sender, key, refund);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    /// @notice Collect fees to treasury.
    function collectFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Fee transfer failed");
        emit FeesCollected(amount, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setWriteFee(uint256 newFee) external onlyOwner {
        uint256 old = writeFee;
        writeFee = newFee;
        emit WriteFeeUpdated(old, newFee);
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

    function getKeyCount(address keyOwner) external view returns (uint256) {
        return _keyCount[keyOwner];
    }

    function keyExists(address keyOwner, bytes32 key) external view returns (bool) {
        return _keyExists[keyOwner][key];
    }

    function hasReadAccess(address keyOwner, bytes32 key, address reader) external view returns (bool) {
        return reader == keyOwner || _readAccess[keyOwner][key][reader];
    }
}
