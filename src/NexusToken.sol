// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Governance token for NexusWeb3 protocol stack. Fixed supply, EIP-2612 permit.
contract NexusToken is ERC20, ERC20Permit {
    constructor(address recipient, uint256 totalSupply_) ERC20("NexusWeb3", "NEXUS") ERC20Permit("NexusWeb3") {
        _mint(recipient, totalSupply_);
    }

    function nonces(address owner) public view override(ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
