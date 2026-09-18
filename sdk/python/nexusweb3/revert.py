"""Decode solidity custom errors (`JobNotFound(99)`) from raw revert data."""

from __future__ import annotations

from typing import Any, Iterable

from eth_abi import decode as abi_decode
from eth_abi.exceptions import DecodingError
from eth_utils.abi import collapse_if_tuple
from eth_utils.crypto import keccak

from .abi import ABI

__all__ = ["ErrorIndex", "build_error_index", "decode_revert"]

#: selector -> (error name, argument types, argument names)
ErrorIndex = dict[bytes, tuple[str, list[str], list[str]]]


def _signature(entry: dict[str, Any]) -> tuple[str, list[str], list[str]]:
    inputs = entry.get("inputs", []) or []
    types = [collapse_if_tuple(dict(i)) for i in inputs]
    names = [str(i.get("name", "")) for i in inputs]
    return f"{entry['name']}({','.join(types)})", types, names


def build_error_index(abi: ABI) -> ErrorIndex:
    """Map every `error` entry in an ABI to its 4-byte selector."""
    index: ErrorIndex = {}
    for entry in abi:
        if entry.get("type") != "error" or "name" not in entry:
            continue
        signature, types, names = _signature(entry)
        index[keccak(text=signature)[:4]] = (entry["name"], types, names)
    return index


def _revert_data(exc: BaseException) -> bytes | None:
    """Pull the hex revert payload out of a web3 exception, whatever shape it arrives in."""
    candidates: Iterable[Any] = (getattr(exc, "data", None), getattr(exc, "message", None), *exc.args)
    for candidate in candidates:
        if isinstance(candidate, dict):
            candidate = candidate.get("data")
        if isinstance(candidate, str) and candidate.startswith("0x") and len(candidate) >= 10:
            try:
                return bytes.fromhex(candidate[2:])
            except ValueError:
                continue
        if isinstance(candidate, (bytes, bytearray)) and len(candidate) >= 4:
            return bytes(candidate)
    return None


def decode_revert(index: ErrorIndex, exc: BaseException) -> str | None:
    """Return a readable `Name(arg=value, …)` for a custom error, or None when undecodable."""
    data = _revert_data(exc)
    if data is None or len(data) < 4:
        return None
    entry = index.get(data[:4])
    if entry is None:
        return None
    name, types, names = entry
    if not types:
        return f"{name}()"
    try:
        values = abi_decode(types, data[4:])
    except (DecodingError, ValueError, OverflowError):  # payload does not match the ABI types
        return f"{name}(<undecodable args>)"
    parts = [
        f"{arg_name or f'arg{i}'}={_format(value)}" for i, (arg_name, value) in enumerate(zip(names, values))
    ]
    return f"{name}({', '.join(parts)})"


def _format(value: Any) -> str:
    if isinstance(value, (bytes, bytearray)):
        return "0x" + bytes(value).hex()
    return str(value)
