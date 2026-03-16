// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IAgentVault is IERC4626 {
    struct OperatorConfig {
        uint128 spendingLimit;
        uint128 spent;
    }

    event OperatorAdded(address indexed operator, uint256 spendingLimit);
    event OperatorRemoved(address indexed operator);
    event OperatorSpendingLimitUpdated(address indexed operator, uint256 newLimit);
    event OperatorSpentReset(address indexed operator);
    event OperatorWithdrawal(address indexed operator, address indexed to, uint256 assets);
    event ProtocolFeeCollected(address indexed depositor, uint256 feeAmount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    error NotOperator(address caller);
    error SpendingLimitExceeded(address operator, uint256 requested, uint256 remaining);
    error OperatorAlreadyExists(address operator);
    error OperatorDoesNotExist(address operator);
    error FeeTooHigh(uint256 bps);
    error ZeroAddress();
    error ZeroAmount();

    function addOperator(address operator, uint128 spendingLimit) external;
    function removeOperator(address operator) external;
    function setSpendingLimit(address operator, uint128 newLimit) external;
    function resetOperatorSpent(address operator) external;
    function operatorWithdraw(uint256 assets, address to) external;
    function getOperatorConfig(address operator) external view returns (OperatorConfig memory);
    function isOperator(address account) external view returns (bool);
    function protocolFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}
