"""EIP-2612 `permit` signing for the payment token.

`AgentEscrowV2.createJobWithPermit` consumes the (v, r, s) produced here, so a client
principal can fund a job without a separate `approve` transaction.
"""

from __future__ import annotations

import logging
from typing import Any

from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.exceptions import Web3Exception

from .abi import ERC20_ABI
from .amount import UsdcAmount, to_base_units

logger = logging.getLogger("nexusweb3")

#: EIP-712 domain version used by most EIP-2612 tokens (OpenZeppelin's ERC20Permit included).
DEFAULT_PERMIT_VERSION = "1"
#: Circle's USDC signs with "2" and exposes no ERC-5267 `eip712Domain()` to say so.
BASE_USDC_PERMIT_VERSION = "2"

#: Tokens whose domain version cannot be discovered on chain, keyed by checksummed address.
#: Only for deployments that lack ERC-5267; anything that implements it is read, not looked up.
KNOWN_PERMIT_VERSIONS: dict[str, str] = {
    # USDC on Base mainnet
    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913": BASE_USDC_PERMIT_VERSION,
    # USDC on Base Sepolia
    "0x036CbD53842c5426634e7929541eC2318f3dCF7e": BASE_USDC_PERMIT_VERSION,
}

PERMIT_TYPES: dict[str, list[dict[str, str]]] = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Permit": [
        {"name": "owner", "type": "address"},
        {"name": "spender", "type": "address"},
        {"name": "value", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
}

__all__ = [
    "DEFAULT_PERMIT_VERSION",
    "BASE_USDC_PERMIT_VERSION",
    "KNOWN_PERMIT_VERSIONS",
    "PERMIT_TYPES",
    "build_permit_typed_data",
    "resolve_permit_version",
    "sign_permit",
]


def resolve_permit_version(w3: Web3, token: str) -> str:
    """Work out the EIP-712 domain version `token` signs permits with.

    Signing under the wrong version produces a signature the token silently rejects, so this
    prefers on-chain truth: ERC-5267 `eip712Domain()` when the token implements it, then a table
    of known deployments that do not (Circle's USDC signs with "2" but exposes no descriptor),
    and finally "1", the version every other EIP-2612 token uses.
    """
    address = Web3.to_checksum_address(token)
    contract = w3.eth.contract(address=address, abi=ERC20_ABI)
    try:
        version = str(contract.functions.eip712Domain().call()[2])
        if version:
            return version
        logger.debug("%s eip712Domain() reports an empty version; falling back", address)
    except (Web3Exception, ValueError, TypeError, IndexError) as exc:
        # Not ERC-5267: the call reverts, or decodes to nothing usable.
        logger.debug("%s has no usable eip712Domain() (%s); falling back", address, exc)
    return KNOWN_PERMIT_VERSIONS.get(address, DEFAULT_PERMIT_VERSION)


def build_permit_typed_data(
    *,
    token: str,
    token_name: str,
    chain_id: int,
    owner: str,
    spender: str,
    value: UsdcAmount,
    nonce: int,
    deadline: int,
    version: str = DEFAULT_PERMIT_VERSION,
) -> dict[str, Any]:
    """The full EIP-712 payload for one `Permit`, ready for `sign_typed_data(full_message=...)`."""
    return {
        "types": PERMIT_TYPES,
        "primaryType": "Permit",
        "domain": {
            "name": token_name,
            "version": version,
            "chainId": int(chain_id),
            "verifyingContract": Web3.to_checksum_address(token),
        },
        "message": {
            "owner": Web3.to_checksum_address(owner),
            "spender": Web3.to_checksum_address(spender),
            "value": to_base_units(value, "value"),
            "nonce": int(nonce),
            "deadline": int(deadline),
        },
    }


def sign_permit(
    account: LocalAccount,
    w3: Web3,
    token: str,
    spender: str,
    value: UsdcAmount,
    deadline: int,
    *,
    version: str | None = None,
    nonce: int | None = None,
    token_name: str | None = None,
) -> tuple[int, bytes, bytes]:
    """Sign an EIP-2612 approval of `value` for `spender`, returning `(v, r, s)`.

    `value` is a human USDC amount (``"250.00"``); pass an ``int`` only when you already hold base
    units. `name()` and `nonces(owner)` are read from the token unless supplied, and the EIP-712
    domain version is discovered by :func:`resolve_permit_version` unless `version` is given.
    """
    token_address = Web3.to_checksum_address(token)
    contract = w3.eth.contract(address=token_address, abi=ERC20_ABI)
    resolved_name = token_name if token_name is not None else str(contract.functions.name().call())
    resolved_nonce = nonce if nonce is not None else int(contract.functions.nonces(account.address).call())
    resolved_version = version if version is not None else resolve_permit_version(w3, token_address)

    typed_data = build_permit_typed_data(
        token=token_address,
        token_name=resolved_name,
        chain_id=int(w3.eth.chain_id),
        owner=account.address,
        spender=spender,
        value=to_base_units(value, "value"),
        nonce=resolved_nonce,
        deadline=deadline,
        version=resolved_version,
    )
    signed = account.sign_typed_data(full_message=typed_data)
    r = int(signed.r).to_bytes(32, "big")
    s = int(signed.s).to_bytes(32, "big")
    return int(signed.v), r, s
