// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Models Circle's FiatToken: transfers involving a blacklisted address REVERT (they do not
///         return false). This is the behaviour of real Base USDC, unlike test/v2/mocks FailingToken.
contract BlacklistRevertToken is ERC20 {
    error Blacklisted(address account);

    mapping(address account => bool) public blacklisted;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}

/// @notice ERC-20 that burns `feeBps` of every transfer. Used to show what a misdeploy with a
///         fee-on-transfer (or negatively rebasing) token does to escrow accounting.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
