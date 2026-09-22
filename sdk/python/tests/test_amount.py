"""Amount handling and EIP-712 permit version detection — the two places a wrong unit or a
wrong domain version turns into a silently mis-signed or mis-sized payment."""

from __future__ import annotations

from typing import Any

import pytest
from web3.exceptions import Web3Exception

from nexusweb3 import (
    DEFAULT_PERMIT_VERSION,
    KNOWN_PERMIT_VERSIONS,
    USDC_DECIMALS,
    CreateParams,
    ZERO_ADDRESS,
    format_usdc,
    parse_usdc,
    resolve_permit_version,
    to_base_units,
)
from nexusweb3.permit import BASE_USDC_PERMIT_VERSION

BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
BASE_SEPOLIA_USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"


# ─── amounts: USDC in, base units on the wire ───────────────────────────
def test_parse_usdc_reads_dollars_not_base_units() -> None:
    assert USDC_DECIMALS == 6
    assert parse_usdc("100") == 100_000_000
    assert parse_usdc("100.50") == 100_500_000
    assert parse_usdc("0.000001") == 1
    assert parse_usdc("0") == 0
    assert parse_usdc(" 250.5 ") == 250_500_000


def test_parse_usdc_refuses_precision_it_would_throw_away() -> None:
    with pytest.raises(ValueError, match="at most 6"):
        parse_usdc("1.0000001")


@pytest.mark.parametrize("bad", ["", "-1", "1e6", "1.2.3", "100 USDC", "0x64", "NaN"])
def test_parse_usdc_refuses_non_decimals(bad: str) -> None:
    with pytest.raises(ValueError):
        parse_usdc(bad)


def test_parse_usdc_names_the_offending_field() -> None:
    with pytest.raises(ValueError, match=r"milestone_amounts\[1\]"):
        parse_usdc("nope", "milestone_amounts[1]")


def test_to_base_units_distinguishes_string_from_int() -> None:
    assert to_base_units("100") == 100_000_000
    assert to_base_units(100) == 100
    assert to_base_units(100_000_000) == 100_000_000
    with pytest.raises(ValueError, match="negative"):
        to_base_units(-1)
    with pytest.raises(TypeError, match="bool"):
        to_base_units(True)


@pytest.mark.parametrize("value", ["0", "1", "100.5", "0.000001", "123456.789012"])
def test_format_usdc_round_trips(value: str) -> None:
    assert format_usdc(parse_usdc(value)) == value


def test_create_params_take_usdc_figures() -> None:
    params = CreateParams(
        client=ZERO_ADDRESS,
        provider=ZERO_ADDRESS,
        milestone_amounts=["100", "150.50"],
        deadline=1,
    )
    assert params.base_unit_amounts() == [100_000_000, 150_500_000]
    assert params.total == 250_500_000
    assert params.to_tuple()[3] == [100_000_000, 150_500_000]


# ─── permit domain version ──────────────────────────────────────────────
class _Call:
    def __init__(self, result: object | Exception) -> None:
        self._result = result

    def call(self) -> object:
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


class _FakeToken:
    """Stands in for `w3.eth.contract(...)`: only `eip712Domain()` matters here."""

    def __init__(self, result: object | Exception) -> None:
        self.functions = type("_Fns", (), {"eip712Domain": lambda _self: _Call(result)})()


def _w3_with(result: object | Exception) -> Any:
    eth = type("_Eth", (), {"contract": lambda _self, **_kw: _FakeToken(result)})()
    return type("_W3", (), {"eth": eth})()


def _descriptor(version: str) -> list[Any]:
    return [b"\x0f", "USD Coin", version, 8453, BASE_USDC, b"\x00" * 32, []]


def test_resolve_permit_version_prefers_the_on_chain_descriptor() -> None:
    # Even for a known address: on-chain truth wins over our copy of it.
    assert resolve_permit_version(_w3_with(_descriptor("7")), BASE_USDC) == "7"


def test_resolve_permit_version_falls_back_to_the_known_address_table() -> None:
    reverted = _w3_with(Web3Exception("execution reverted"))
    assert resolve_permit_version(reverted, BASE_USDC) == BASE_USDC_PERMIT_VERSION
    assert resolve_permit_version(reverted, BASE_SEPOLIA_USDC) == BASE_USDC_PERMIT_VERSION


def test_resolve_permit_version_defaults_to_one_for_an_unknown_token() -> None:
    reverted = _w3_with(Web3Exception("execution reverted"))
    unknown = "0x000000000000000000000000000000000000dead"
    assert resolve_permit_version(reverted, unknown) == DEFAULT_PERMIT_VERSION
    assert DEFAULT_PERMIT_VERSION == "1"


def test_resolve_permit_version_ignores_an_empty_version() -> None:
    assert resolve_permit_version(_w3_with(_descriptor("")), BASE_USDC) == BASE_USDC_PERMIT_VERSION


def test_known_permit_versions_pin_both_circle_deployments() -> None:
    assert KNOWN_PERMIT_VERSIONS[BASE_USDC] == "2"
    assert KNOWN_PERMIT_VERSIONS[BASE_SEPOLIA_USDC] == "2"
