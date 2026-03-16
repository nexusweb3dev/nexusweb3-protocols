// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";

/// @notice Mock aToken that tracks deposits and simulates yield via manual mint.
contract MockAToken is ERC20 {
    address public underlying;

    constructor(address underlying_) ERC20("Mock aUSDC", "aUSDC") {
        underlying = underlying_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Mock Aave pool: supply mints aTokens 1:1, withdraw burns aTokens and transfers underlying.
contract MockAavePool is IAavePool {
    MockAToken public aToken;
    IERC20 public underlying;

    constructor(IERC20 underlying_, MockAToken aToken_) {
        underlying = underlying_;
        aToken = aToken_;
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external override {
        underlying.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external override returns (uint256) {
        aToken.burn(msg.sender, amount);
        underlying.transfer(to, amount);
        return amount;
    }

    /// @notice Simulate yield by minting extra aTokens to a vault address.
    function simulateYield(address vault, uint256 amount) external {
        aToken.mint(vault, amount);
    }
}
