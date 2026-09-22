"""One definition of "an amount" for the whole SDK: human USDC in, base units on the wire.

USDC has 6 decimals on every Circle deployment, and the v2 contracts assume it — escrow
milestones, kill-switch spending limits and reputation volume are all denominated in these units.
"""

from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation
from typing import Union

USDC_DECIMALS = 6

#: An amount of the payment token. A ``str`` is a human USDC amount (``"100.50"`` is one hundred
#: dollars fifty) — the form every surface accepts and the only form the CLI and MCP tools take.
#: An ``int`` is an escape hatch for callers already holding base units (``100_500_000``). The
#: type, not the digits, decides; no value could mean either.
UsdcAmount = Union[str, int]

_DECIMAL_PATTERN = re.compile(r"^(\d+)(?:\.(\d*))?$")

__all__ = ["USDC_DECIMALS", "UsdcAmount", "parse_usdc", "to_base_units", "format_usdc"]


def parse_usdc(amount: str, label: str = "amount", decimals: int = USDC_DECIMALS) -> int:
    """Parse a human USDC amount into base units.

    Rejects anything that is not a plain non-negative decimal, and anything finer than `decimals`
    places rather than silently truncating a payment.
    """
    text = str(amount).strip()
    match = _DECIMAL_PATTERN.match(text)
    if not match:
        raise ValueError(
            f'{label} must be a non-negative decimal USDC amount such as "100.50", got "{amount}"'
        )
    fraction = match.group(2) or ""
    if len(fraction) > decimals:
        raise ValueError(
            f'{label} "{amount}" has {len(fraction)} decimal places; USDC holds at most {decimals}'
        )
    try:
        scaled = Decimal(text) * (Decimal(10) ** decimals)
    except InvalidOperation as exc:  # unreachable for pattern-matched input, but never guess
        raise ValueError(f"{label} {amount!r} is not a usable decimal") from exc
    return int(scaled)


def to_base_units(amount: UsdcAmount, label: str = "amount", decimals: int = USDC_DECIMALS) -> int:
    """Normalize either form of :data:`UsdcAmount` to base units."""
    if isinstance(amount, bool):  # bool is an int subclass; an amount is never a flag
        raise TypeError(f"{label} must be a USDC string or an int in base units, got a bool")
    if isinstance(amount, int):
        if amount < 0:
            raise ValueError(f"{label} must not be negative, got {amount}")
        return amount
    return parse_usdc(amount, label, decimals)


def format_usdc(amount: int, decimals: int = USDC_DECIMALS) -> str:
    """Render base units as a human USDC string, the inverse of :func:`parse_usdc`."""
    value = Decimal(int(amount)) / (Decimal(10) ** decimals)
    return format(value.normalize(), "f")
