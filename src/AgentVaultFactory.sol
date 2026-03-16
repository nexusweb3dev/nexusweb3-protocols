// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AgentVault} from "./AgentVault.sol";

/// @notice Factory for deploying AgentVault instances with CREATE2 deterministic addresses.
contract AgentVaultFactory is Ownable {
    event VaultCreated(
        address indexed vault,
        address indexed owner,
        address indexed asset,
        string name,
        string symbol,
        bytes32 salt
    );
    event DefaultFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DefaultFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    error ZeroAddress();
    error VaultAlreadyDeployed(address predicted);

    address public defaultFeeRecipient;
    uint256 public defaultFeeBps;
    address[] private _deployedVaults;
    mapping(address => address[]) private _vaultsByOwner;

    constructor(address owner_, address feeRecipient_, uint256 feeBps_) Ownable(owner_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        defaultFeeRecipient = feeRecipient_;
        defaultFeeBps = feeBps_;
    }

    function createVault(
        IERC20 asset,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    ) external returns (address vault) {
        bytes32 fullSalt = keccak256(abi.encodePacked(msg.sender, salt));

        address predicted = predictVaultAddress(asset, name, symbol, msg.sender, fullSalt);
        if (predicted.code.length > 0) revert VaultAlreadyDeployed(predicted);

        vault = address(
            new AgentVault{salt: fullSalt}(asset, name, symbol, msg.sender, defaultFeeRecipient, defaultFeeBps)
        );

        _deployedVaults.push(vault);
        _vaultsByOwner[msg.sender].push(vault);

        emit VaultCreated(vault, msg.sender, address(asset), name, symbol, salt);
    }

    function predictVaultAddress(
        IERC20 asset,
        string calldata name,
        string calldata symbol,
        address vaultOwner,
        bytes32 fullSalt
    ) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(AgentVault).creationCode,
            abi.encode(asset, name, symbol, vaultOwner, defaultFeeRecipient, defaultFeeBps)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), fullSalt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function setDefaultFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = defaultFeeRecipient;
        defaultFeeRecipient = newRecipient;
        emit DefaultFeeRecipientUpdated(old, newRecipient);
    }

    function setDefaultFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 500) revert FeeTooHigh(newBps);
        uint256 old = defaultFeeBps;
        defaultFeeBps = newBps;
        emit DefaultFeeBpsUpdated(old, newBps);
    }

    error FeeTooHigh(uint256 bps);

    function getDeployedVaults() external view returns (address[] memory) {
        return _deployedVaults;
    }

    function getVaultsByOwner(address vaultOwner) external view returns (address[] memory) {
        return _vaultsByOwner[vaultOwner];
    }

    function deployedVaultCount() external view returns (uint256) {
        return _deployedVaults.length;
    }
}
