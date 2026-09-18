// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title ERC20PermitMock
/// @notice EIP-2612 test token for the Python SDK end-to-end run. The repo's ERC20Mock (used by
///         script/v2/DeployLocal.s.sol) has no `permit`, so `createJobWithPermit` cannot be
///         exercised against it. Build with:
///         forge build --contracts sdk/python/contracts --out sdk/python/.forge-out
contract ERC20PermitMock is ERC20, ERC20Permit {
    uint8 private immutable _decimalsValue;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _decimalsValue = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }
}
