// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Minimal ERC-721 with open minting, used to stand in for an ERC-8004 identity registry.
contract MockERC721 is ERC721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, uint256 id) public {
        _mint(to, id);
    }
}
