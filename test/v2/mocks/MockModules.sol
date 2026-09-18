// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @notice Minimal stand-in for IAgentReputationV2. Records the last call and every per-agent
///         tally the escrow tests assert on, and can be told to revert so the best-effort
///         (try/catch) hook in EscrowBase can be exercised.
contract MockReputation {
    error MockReputationReverted();

    bool public shouldRevert;
    uint256 public callCount;

    address public lastAgent;
    bool public lastPositive;
    uint8 public lastCategory;
    uint256 public lastValue;

    mapping(address agent => uint256) public positives;
    mapping(address agent => uint256) public negatives;
    mapping(address agent => uint256) public lastValueOf;
    mapping(address agent => bool) public lastPositiveOf;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function recordInteraction(address agent, bool positive, uint8 category, uint256 valueUsdc) external {
        if (shouldRevert) revert MockReputationReverted();
        callCount += 1;
        lastAgent = agent;
        lastPositive = positive;
        lastCategory = category;
        lastValue = valueUsdc;
        lastValueOf[agent] = valueUsdc;
        lastPositiveOf[agent] = positive;
        if (positive) {
            positives[agent] += 1;
        } else {
            negatives[agent] += 1;
        }
    }
}

/// @notice Minimal stand-in for IAgentAuditLogV2.
contract MockAuditLog {
    error MockAuditLogReverted();

    bool public shouldRevert;
    uint256 public callCount;

    address public lastAgent;
    bytes32 public lastActionType;
    bytes32 public lastDataHash;
    uint256 public lastValue;

    mapping(address agent => uint256) public logsOf;
    mapping(bytes32 actionType => uint256) public actionCount;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function log(address agent, bytes32 actionType, bytes32 dataHash, uint256 value) external returns (uint256 logId) {
        if (shouldRevert) revert MockAuditLogReverted();
        logId = callCount;
        callCount += 1;
        lastAgent = agent;
        lastActionType = actionType;
        lastDataHash = dataHash;
        lastValue = value;
        logsOf[agent] += 1;
        actionCount[actionType] += 1;
    }
}

/// @notice Minimal stand-in for IAgentKillSwitchV2. `isActive` is settable per agent and `consume`
///         records its arguments and can be forced to revert (the escrow call is strict).
contract MockKillSwitch {
    error MockKillSwitchReverted();

    mapping(address agent => bool) private _inactive;
    bool public consumeShouldRevert;

    uint256 public consumeCount;
    address public lastConsumeAgent;
    uint256 public lastConsumeAmount;

    function setInactive(address agent, bool value) external {
        _inactive[agent] = value;
    }

    function setConsumeShouldRevert(bool value) external {
        consumeShouldRevert = value;
    }

    function isActive(address agent) external view returns (bool) {
        return !_inactive[agent];
    }

    function consume(address agent, uint256 amount) external {
        if (consumeShouldRevert) revert MockKillSwitchReverted();
        consumeCount += 1;
        lastConsumeAgent = agent;
        lastConsumeAmount = amount;
    }
}

/// @notice Minimal stand-in for IFeeRouter. The escrow transfers the fee here first, then calls
///         `route`; the call is strict so a revert must propagate.
contract MockFeeRouter {
    error MockFeeRouterReverted();

    bool public shouldRevert;
    uint256 public routeCount;
    address public lastAgent;
    uint256 public lastAmount;
    uint256 public totalRouted;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function route(address agent, uint256 amount) external {
        if (shouldRevert) revert MockFeeRouterReverted();
        routeCount += 1;
        lastAgent = agent;
        lastAmount = amount;
        totalRouted += amount;
    }
}

/// @notice 6-decimal ERC-20 with EIP-2612 permit, for createJobWithPermit coverage.
contract PermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Permit USD Coin", "pUSDC") ERC20Permit("Permit USD Coin") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice ERC-20 whose `transfer` silently returns false for blocked recipients, so the escrow's
///         claimable fallback in `_payOut` can be exercised. `transferFrom` is untouched.
contract FailingToken is ERC20Mock {
    mapping(address account => bool) public blocked;

    constructor() ERC20Mock("Failing USD Coin", "fUSDC", 6) {}

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, amount);
    }
}
