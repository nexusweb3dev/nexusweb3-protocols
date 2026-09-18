// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Stand-in for the v1 AgentReferral sink: pulls `bps` of the fee from the caller when the
///         agent has a registered referrer, and can be forced to revert to test router resilience.
contract MockReferral {
    using SafeERC20 for IERC20;

    error MockReferralReverted();
    error InvalidFeeToken(address feeToken);

    IERC20 public immutable token;
    uint256 public immutable bps;

    mapping(address => address) public referrerOf;
    mapping(address => uint256) public pending;
    bool public shouldRevert;

    constructor(IERC20 token_, uint256 bps_) {
        token = token_;
        bps = bps_;
    }

    function setReferrer(address agent, address ref) external {
        referrerOf[agent] = ref;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function recordFee(address agent, uint256 feeAmount, address feeToken) external payable {
        if (shouldRevert) revert MockReferralReverted();
        if (feeToken != address(token)) revert InvalidFeeToken(feeToken);

        address ref = referrerOf[agent];
        if (ref == address(0)) return;

        uint256 reward = (feeAmount * bps) / 10_000;
        if (reward == 0) return;

        pending[ref] += reward;
        token.safeTransferFrom(msg.sender, address(this), reward);
    }
}
