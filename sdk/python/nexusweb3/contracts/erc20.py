"""The payment token (USDC on Base) — ERC-20 plus the EIP-2612 views."""

from __future__ import annotations

from web3 import Web3

from ..amount import USDC_DECIMALS, UsdcAmount, format_usdc, parse_usdc, to_base_units
from ..tx import TxResult
from .base import ContractClient

__all__ = ["ERC20Client"]


class ERC20Client(ContractClient):
    """Approvals, balances and the `nonces`/`name` reads that permit signing needs.

    Writes take a USDC figure in dollars; reads return base units, which is what the chain stores.
    :func:`nexusweb3.amount.format_usdc` turns one back into the other.
    """

    def name(self) -> str:
        return str(self._call("name"))

    def symbol(self) -> str:
        return str(self._call("symbol"))

    def decimals(self) -> int:
        return int(self._call("decimals"))

    def total_supply(self) -> int:
        return int(self._call("totalSupply"))

    def balance_of(self, account: str) -> int:
        return int(self._call("balanceOf", Web3.to_checksum_address(account)))

    def allowance(self, owner: str, spender: str) -> int:
        return int(
            self._call("allowance", Web3.to_checksum_address(owner), Web3.to_checksum_address(spender))
        )

    def nonces(self, owner: str) -> int:
        """EIP-2612 permit nonce. Raises if the token does not implement it."""
        return int(self._call("nonces", Web3.to_checksum_address(owner)))

    def approve(self, spender: str, value: UsdcAmount) -> TxResult:
        """Approve `value` USDC for `spender`, e.g. ``approve(escrow, "1000")``."""
        return self._send("approve", Web3.to_checksum_address(spender), to_base_units(value))

    def transfer(self, to: str, value: UsdcAmount) -> TxResult:
        return self._send("transfer", Web3.to_checksum_address(to), to_base_units(value))

    @staticmethod
    def to_units(amount: UsdcAmount, decimals: int = USDC_DECIMALS) -> int:
        """Convert a USDC figure ("100.50") into base units. Alias of :func:`parse_usdc`."""
        return parse_usdc(str(amount), "amount", decimals)

    @staticmethod
    def from_units(amount: int, decimals: int = USDC_DECIMALS) -> str:
        """Format base units as a USDC figure. Alias of :func:`format_usdc`."""
        return format_usdc(int(amount), decimals)
