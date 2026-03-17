// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentLicense {
    enum LicenseType { PER_USE, SUBSCRIPTION, PERPETUAL }

    struct License {
        address ipOwner;
        string name;
        bytes32 contentHash;
        uint256 pricePerUse;
        uint256 subscriptionPrice;
        uint256 totalRoyalties;
        uint256 claimedRoyalties;
        uint256 totalUses;
        bool active;
    }

    struct Licensee {
        bool hasPerpetual;
        uint48 subscriptionEnd;
        uint256 usesRemaining;
    }

    event LicenseRegistered(uint256 indexed licenseId, address indexed ipOwner, string name, bytes32 contentHash);
    event LicensePurchased(uint256 indexed licenseId, address indexed buyer, uint8 licenseType, uint256 paid);
    event UsageRecorded(uint256 indexed licenseId, address indexed user);
    event RoyaltiesTransferred(uint256 indexed licenseId, address indexed ipOwner, uint256 amount);
    event LicenseDeactivated(uint256 indexed licenseId);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error LicenseNotFound(uint256 licenseId);
    error LicenseNotActive(uint256 licenseId);
    error NotIPOwner(uint256 licenseId);
    error InvalidContentHash();
    error InvalidPrice();
    error InvalidLicenseType(uint8 licenseType);
    error AlreadyHasPerpetual(uint256 licenseId, address agent);
    error NoValidLicense(uint256 licenseId, address agent);
    error NoUsesRemaining(uint256 licenseId, address agent);
    error NoRoyaltiesToClaim(uint256 licenseId);
    error EmptyName();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NoFeesToCollect();
}
