"""Exceptions raised by the SDK."""

from __future__ import annotations

from typing import Any

__all__ = ["NexusError", "MissingSignerError", "TransactionFailed", "ContractRevert"]


class NexusError(Exception):
    """Base class for every error raised by this SDK."""


class MissingSignerError(NexusError):
    """A write was attempted on a client constructed without an account."""

    def __init__(self, function_name: str) -> None:
        super().__init__(f"{function_name} needs a signing account; construct NexusClient(account=...)")
        self.function_name = function_name


class TransactionFailed(NexusError):
    """A mined transaction reverted (receipt status 0)."""

    def __init__(self, tx_hash: str, receipt: Any) -> None:
        super().__init__(f"transaction {tx_hash} reverted")
        self.tx_hash = tx_hash
        self.receipt = receipt


class ContractRevert(NexusError):
    """A call or gas estimate reverted with a decoded solidity custom error."""

    def __init__(self, contract: str, function_name: str, error: str) -> None:
        super().__init__(f"{contract}.{function_name} reverted: {error}")
        self.contract = contract
        self.function_name = function_name
        self.error = error
