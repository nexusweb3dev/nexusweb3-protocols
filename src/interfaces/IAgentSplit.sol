// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentSplit {
    struct Split {
        address splitOwner;
        address[] recipients;
        uint256[] shares;
        string description;
        uint256 totalReceived;
        bool active;
    }

    event SplitCreated(uint256 indexed splitId, address indexed splitOwner, uint256 recipientCount);
    event PaymentSplit(uint256 indexed splitId, uint256 totalAmount, uint256 fee);
    event SharesUpdated(uint256 indexed splitId);
    event SplitDeactivated(uint256 indexed splitId);
    event ClaimableStored(address indexed recipient, uint256 amount);
    event ClaimableWithdrawn(address indexed recipient, uint256 amount);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 amount, address indexed treasury);

    error SplitNotFound(uint256 splitId);
    error SplitNotActive(uint256 splitId);
    error NotSplitOwner(uint256 splitId);
    error InvalidShares();
    error NoRecipients();
    error TooManyRecipients(uint256 count);
    error RecipientNotFound(address recipient);
    error DuplicateRecipient(address recipient);
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAmount();
    error ZeroAddress();
    error NothingToClaim();
    error NoFeesToCollect();
    error FeeTooHigh(uint256 bps);
    error EmptyDescription();
}
