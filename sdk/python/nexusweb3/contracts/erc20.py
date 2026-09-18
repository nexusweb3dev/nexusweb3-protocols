"""The payment token (USDC on Base) — ERC-20 plus the EIP-2612 views."""

from __future__ import annotations

from decimal import Decimal

from web3 import Web3

from ..tx import TxResult
from .base import ContractClient

__all__ = ["ERC20Client"]


class ERC20Client(ContractClient):
    """Approvals, balances and the `nonces`/`name` reads that permit signing needs."""

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

    def approve(self, spender: str, value: int) -> TxResult:
        return self._send("approve", Web3.to_checksum_address(spender), int(value))

    def transfer(self, to: str, value: int) -> TxResult:
        return self._send("transfer", Web3.to_checksum_address(to), int(value))

    @staticmethod
    def to_units(amount: float | int | str, decimals: int = 6) -> int:
        """Convert a human amount ("100.50") into base units."""
        scaled = Decimal(str(amount)) * (Decimal(10) ** decimals)
        if scaled != scaled.to_integral_value():
            raise ValueError(f"{amount} has more than {decimals} decimal places")
        return int(scaled)

    @staticmethod
    def from_units(amount: int, decimals: int = 6) -> str:
        """Format base units as a decimal string."""
        return str(Decimal(int(amount)) / (Decimal(10) ** decimals))
