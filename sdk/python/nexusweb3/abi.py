"""ABI loading for the packaged v2 artifacts."""

from __future__ import annotations

import json
from functools import lru_cache
from importlib import resources
from typing import Any

ABI = list[dict[str, Any]]

CONTRACT_NAMES: tuple[str, ...] = (
    "AgentAccess",
    "AgentIdentityV2",
    "AgentReputationV2",
    "AgentKillSwitchV2",
    "AgentAuditLogV2",
    "FeeRouter",
    "AgentEscrowV2",
)

#: Minimal ERC-20 + EIP-2612 surface, enough for approvals, balances and permit signing.
ERC20_ABI: ABI = [
    {
        "type": "function",
        "name": "name",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "string"}],
    },
    {
        "type": "function",
        "name": "symbol",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "string"}],
    },
    {
        "type": "function",
        "name": "decimals",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint8"}],
    },
    {
        "type": "function",
        "name": "totalSupply",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "balanceOf",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "allowance",
        "stateMutability": "view",
        "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "nonces",
        "stateMutability": "view",
        "inputs": [{"name": "owner", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "DOMAIN_SEPARATOR",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "bytes32"}],
    },
    {
        "type": "function",
        "name": "approve",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "spender", "type": "address"}, {"name": "value", "type": "uint256"}],
        "outputs": [{"name": "", "type": "bool"}],
    },
    {
        "type": "function",
        "name": "transfer",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "to", "type": "address"}, {"name": "value", "type": "uint256"}],
        "outputs": [{"name": "", "type": "bool"}],
    },
]

__all__ = ["ABI", "CONTRACT_NAMES", "ERC20_ABI", "load_abi"]


@lru_cache(maxsize=None)
def load_abi(contract: str) -> ABI:
    """Return the packaged ABI for one v2 contract, e.g. ``load_abi("AgentEscrowV2")``."""
    if contract not in CONTRACT_NAMES:
        raise KeyError(f"unknown contract '{contract}'; expected one of {', '.join(CONTRACT_NAMES)}")
    resource = resources.files("nexusweb3").joinpath("abis", f"{contract}.json")
    if not resource.is_file():
        raise FileNotFoundError(
            f"ABI for {contract} is not packaged; run `python scripts/sync_abis.py` after `forge build`"
        )
    data = json.loads(resource.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"ABI for {contract} must be a JSON array")
    return data
