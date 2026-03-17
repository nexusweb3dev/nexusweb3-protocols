// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentInsolvency {
    struct Debt {
        address debtor;
        address creditor;
        uint256 originalAmount;
        uint256 remainingAmount;
        uint48 dueDate;
        string description;
        bool confirmed;
        bool resolved;
    }

    struct SolvencyStatus {
        uint256 totalDebts;
        uint256 poolBalance;
        bool isSolvent;
    }

    event DebtRegistered(uint256 indexed debtId, address indexed debtor, address indexed creditor, uint256 amount);
    event DebtConfirmed(uint256 indexed debtId, address indexed creditor);
    event DebtRepaid(uint256 indexed debtId, uint256 amount, uint256 remaining);
    event InsolvencyDeclared(address indexed agent, uint256 totalConfirmedDebt);
    event InsolvencyPayout(address indexed agent, address indexed creditor, uint256 payout);
    event PlatformFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(uint256 ethAmount, uint256 usdcAmount, address indexed treasury);

    error DebtNotFound(uint256 debtId);
    error NotDebtor(uint256 debtId);
    error NotCreditor(uint256 debtId);
    error DebtAlreadyConfirmed(uint256 debtId);
    error DebtNotConfirmed(uint256 debtId);
    error DebtAlreadyResolved(uint256 debtId);
    error RepaymentExceedsDebt(uint256 debtId, uint256 amount, uint256 remaining);
    error NotInsolvent(address agent);
    error AlreadyInsolvent(address agent);
    error NotDebtorOrOwner(address agent, address caller);
    error NoAssetsToDistribute(address agent);
    error InvalidAmount();
    error InvalidDueDate();
    error SelfDebt();
    error EmptyDescription();
    error InsufficientFee(uint256 required, uint256 provided);
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NoFeesToCollect();
    error NoPendingClaims(address agent);
    error TooManyDebts(address agent);
}
