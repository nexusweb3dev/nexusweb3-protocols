// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IAgentYield} from "./interfaces/IAgentYield.sol";

/// @notice ERC-4626 yield vault for AI agents. Deposits USDC into Aave v3, takes 10% performance fee on yield.
contract AgentYield is ERC4626, Ownable, ReentrancyGuard, Pausable, IAgentYield {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 3000; // 30% hard cap
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IAavePool public immutable aavePool;
    IERC20 public immutable aToken;

    uint256 public performanceFeeBps;
    address public treasury;
    uint256 public lastHarvestedAssets;
    uint256 public totalFeeCollected;

    constructor(
        IERC20 asset_,
        IAavePool aavePool_,
        IERC20 aToken_,
        address treasury_,
        address owner_,
        uint256 feeBps_
    ) ERC4626(asset_) ERC20("Agent Yield USDC", "ayUSDC") Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (address(aavePool_) == address(0)) revert ZeroAddress();
        if (address(aToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);

        aavePool = aavePool_;
        aToken = aToken_;
        treasury = treasury_;
        performanceFeeBps = feeBps_;

        // approve Aave pool to pull USDC
        IERC20(asset()).forceApprove(address(aavePool_), type(uint256).max);
    }

    // ─── ERC4626 Core ───────────────────────────────────────────────────

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused nonReentrant {
        // pull USDC from caller
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        // mint shares
        _mint(receiver, shares);
        // supply to Aave
        aavePool.supply(asset(), assets, address(this), 0);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        // no whenNotPaused — users can always exit
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        // withdraw from Aave directly to receiver
        aavePool.withdraw(asset(), assets, receiver);

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    // ─── Harvest (collect yield, take fee) ──────────────────────────────

    function harvest() external nonReentrant {
        uint256 currentAssets = totalAssets();
        uint256 deposited = lastHarvestedAssets;

        // on first harvest, set baseline
        if (deposited == 0 && totalSupply() > 0) {
            lastHarvestedAssets = currentAssets;
            return;
        }

        if (currentAssets <= deposited) revert NoYieldToHarvest();

        uint256 yieldAmount = currentAssets - deposited;
        uint256 fee = yieldAmount.mulDiv(performanceFeeBps, BPS_DENOMINATOR, Math.Rounding.Floor);

        // CEI: update state before external call
        totalFeeCollected += fee;
        // estimate post-withdrawal balance (currentAssets - fee)
        lastHarvestedAssets = currentAssets - fee;

        if (fee > 0) {
            aavePool.withdraw(asset(), fee, treasury);
        }

        emit YieldHarvested(yieldAmount, fee, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setPerformanceFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps);
        uint256 old = performanceFeeBps;
        performanceFeeBps = newBps;
        emit PerformanceFeeBpsUpdated(old, newBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View overrides ─────────────────────────────────────────────────

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }
}
