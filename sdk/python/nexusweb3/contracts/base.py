"""Shared plumbing for the per-contract sub-clients."""

from __future__ import annotations

from typing import Any, Sequence

from web3 import Web3
from web3.contract.contract import Contract, ContractFunction
from web3.exceptions import Web3Exception
from web3.logs import DISCARD

from ..abi import ABI
from ..errors import ContractRevert
from ..revert import build_error_index, decode_revert
from ..tx import TxResult, TxSender

__all__ = ["ContractClient"]


class ContractClient:
    """Wraps one deployed contract with read, write and event-decoding helpers."""

    def __init__(self, w3: Web3, address: str, abi: ABI, sender: TxSender) -> None:
        self._w3 = w3
        self._sender = sender
        self._contract: Contract = w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)
        self._errors = build_error_index(abi)

    @property
    def address(self) -> str:
        return self._contract.address

    @property
    def contract(self) -> Contract:
        """The underlying web3 contract, for calls this SDK does not wrap."""
        return self._contract

    @property
    def sender_address(self) -> str:
        """Address of the signing account."""
        return self._sender.address

    def _fn(self, name: str, *args: Any) -> ContractFunction:
        return self._contract.get_function_by_name(name)(*args)

    def _call(self, name: str, *args: Any) -> Any:
        try:
            return self._fn(name, *args).call()
        except Web3Exception as exc:
            raise self._as_revert(name, exc) from exc

    def _send(self, name: str, *args: Any) -> TxResult:
        try:
            return self._sender.send(self._fn(name, *args))
        except Web3Exception as exc:
            raise self._as_revert(name, exc) from exc

    def _as_revert(self, function_name: str, exc: Web3Exception) -> Exception:
        """Turn a raw revert into :class:`ContractRevert`, or re-raise the original error."""
        decoded = decode_revert(self._errors, exc)
        if decoded is None:
            return exc
        return ContractRevert(type(self).__name__, function_name, decoded)

    def _event_args(self, event_name: str, receipt: Any) -> list[dict[str, Any]]:
        """Decode every occurrence of one event in a receipt, ignoring unrelated logs."""
        event = self._contract.events[event_name]()
        return [dict(entry["args"]) for entry in event.process_receipt(receipt, errors=DISCARD)]

    def _first_event_arg(self, event_name: str, receipt: Any, key: str) -> int | None:
        args = self._event_args(event_name, receipt)
        if not args:
            return None
        return int(args[0][key])

    @staticmethod
    def _tuples(values: Sequence[Any]) -> list[Any]:
        return list(values)
