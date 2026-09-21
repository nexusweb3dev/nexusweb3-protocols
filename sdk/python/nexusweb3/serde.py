"""JSON-safe conversion of SDK values (dataclasses, enums, bytes, big ints)."""

from __future__ import annotations

import json
from dataclasses import fields, is_dataclass
from enum import Enum
from typing import Any, Mapping, Sequence

__all__ = ["to_jsonable", "dumps"]


def to_jsonable(value: Any) -> Any:
    """Recursively convert `value` into something :func:`json.dumps` accepts."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, (bytes, bytearray)):
        return "0x" + bytes(value).hex()
    if is_dataclass(value) and not isinstance(value, type):
        return {f.name: to_jsonable(getattr(value, f.name)) for f in fields(value)}
    if isinstance(value, Mapping):
        return {str(k): to_jsonable(v) for k, v in value.items()}
    if isinstance(value, Sequence):
        return [to_jsonable(v) for v in value]
    return str(value)


def dumps(value: Any, *, indent: int = 2) -> str:
    """Serialize `value` to a JSON string."""
    return json.dumps(to_jsonable(value), indent=indent)
