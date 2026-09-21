"""Deployment addresses for a v2 core stack."""

from __future__ import annotations

import json
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any, Mapping

from eth_utils.address import to_checksum_address

from .types import ZERO_ADDRESS

#: Canonical ERC-8004 Identity Registry on Base. `AgentIdentityV2.linkERC8004` checks ownership here.
BASE_ERC8004_IDENTITY_REGISTRY = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"

#: Maps `deployments/v2-*.json` keys onto :class:`Addresses` fields.
_JSON_KEYS: dict[str, str] = {
    "AgentAccess": "access",
    "AgentIdentityV2": "identity",
    "AgentReputationV2": "reputation",
    "AgentKillSwitchV2": "kill_switch",
    "AgentAuditLogV2": "audit_log",
    "FeeRouter": "fee_router",
    "AgentEscrowV2": "escrow",
    "paymentToken": "payment_token",
}

__all__ = ["Addresses", "load_addresses", "BASE_ERC8004_IDENTITY_REGISTRY"]


@dataclass(frozen=True)
class Addresses:
    """Checksummed addresses of one deployed v2 stack."""

    access: str
    identity: str
    reputation: str
    kill_switch: str
    audit_log: str
    fee_router: str
    escrow: str
    payment_token: str
    erc8004_registry: str = ZERO_ADDRESS

    def __post_init__(self) -> None:
        for field in fields(self):
            value = getattr(self, field.name)
            if not isinstance(value, str):
                raise TypeError(f"{field.name} must be a hex address string, got {type(value).__name__}")
            object.__setattr__(self, field.name, to_checksum_address(value))

    def to_dict(self) -> dict[str, str]:
        return {field.name: getattr(self, field.name) for field in fields(self)}


def _read_mapping(path_or_dict: str | Path | Mapping[str, Any]) -> Mapping[str, Any]:
    if isinstance(path_or_dict, Mapping):
        return path_or_dict
    path = Path(path_or_dict)
    if not path.is_file():
        raise FileNotFoundError(f"deployment file not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(data, Mapping):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def load_addresses(path_or_dict: str | Path | Mapping[str, Any]) -> Addresses:
    """Load a `deployments/v2-<chain>.json` file (or an equivalent mapping) into :class:`Addresses`.

    Accepts both the deployment-file keys (``AgentAccess``, ``paymentToken``, …) and the
    dataclass field names (``access``, ``payment_token``, …).
    """
    data = _read_mapping(path_or_dict)
    kwargs: dict[str, str] = {}
    for json_key, field_name in _JSON_KEYS.items():
        if json_key in data:
            kwargs[field_name] = str(data[json_key])
        elif field_name in data:
            kwargs[field_name] = str(data[field_name])
        else:
            raise KeyError(f"deployment data is missing '{json_key}'")

    registry = data.get("erc8004Registry", data.get("erc8004_registry"))
    if registry:
        kwargs["erc8004_registry"] = str(registry)
    return Addresses(**kwargs)
