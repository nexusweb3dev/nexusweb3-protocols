// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IAgentYield is IERC4626 {
    event YieldHarvested(uint256 yieldAmount, uint256 feeAmount, address indexed treasury);
    event PerformanceFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint256 bps);
    error NoYieldToHarvest();

    function harvest() external;
    function performanceFeeBps() external view returns (uint256);
    function treasury() external view returns (address);
    function lastHarvestedAssets() external view returns (uint256);
    function totalFeeCollected() external view returns (uint256);
}
