// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentStorage {
    event ValueSet(address indexed owner, bytes32 indexed key, uint256 size);
    event ValueDeleted(address indexed owner, bytes32 indexed key, uint256 refund);
    event ReadAccessGranted(address indexed owner, bytes32 indexed key, address indexed reader);
    event ReadAccessRevoked(address indexed owner, bytes32 indexed key, address indexed reader);
    event WriteFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error NotKeyOwner(bytes32 key);
    error KeyTaken(bytes32 key, address existingOwner);
    error ValueTooLarge(uint256 size, uint256 max);
    error EmptyValue();
    error KeyNotFound(address owner, bytes32 key);
    error MaxKeysReached(address owner);
    error NoReadAccess(address caller, address owner, bytes32 key);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error NoFeesToCollect();
}
