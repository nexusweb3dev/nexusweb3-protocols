"""EIP-2612 `permit` signing for the payment token.

`AgentEscrowV2.createJobWithPermit` consumes the (v, r, s) produced here, so a client
principal can fund a job without a separate `approve` transaction.
"""

from __future__ import annotations

from typing import Any

from eth_account.signers.local import LocalAccount
from web3 import Web3

from .abi import ERC20_ABI

#: EIP-712 domain version used by most EIP-2612 tokens. Base USDC uses "2".
DEFAULT_PERMIT_VERSION = "1"
BASE_USDC_PERMIT_VERSION = "2"

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
    "PERMIT_TYPES",
    "build_permit_typed_data",
    "sign_permit",
]


def build_permit_typed_data(
    *,
    token: str,
    token_name: str,
    chain_id: int,
    owner: str,
    spender: str,
    value: int,
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
            "value": int(value),
            "nonce": int(nonce),
            "deadline": int(deadline),
        },
    }


def sign_permit(
    account: LocalAccount,
    w3: Web3,
    token: str,
    spender: str,
    value: int,
    deadline: int,
    *,
    version: str = DEFAULT_PERMIT_VERSION,
    nonce: int | None = None,
    token_name: str | None = None,
) -> tuple[int, bytes, bytes]:
    """Sign an EIP-2612 approval of `value` for `spender`, returning `(v, r, s)`.

    `name()` and `nonces(owner)` are read from the token unless supplied. Pass
    ``version=BASE_USDC_PERMIT_VERSION`` for Base USDC, whose domain version is "2".
    """
    token_address = Web3.to_checksum_address(token)
    contract = w3.eth.contract(address=token_address, abi=ERC20_ABI)
    resolved_name = token_name if token_name is not None else str(contract.functions.name().call())
    resolved_nonce = nonce if nonce is not None else int(contract.functions.nonces(account.address).call())

    typed_data = build_permit_typed_data(
        token=token_address,
        token_name=resolved_name,
        chain_id=int(w3.eth.chain_id),
        owner=account.address,
        spender=spender,
        value=value,
        nonce=resolved_nonce,
        deadline=deadline,
        version=version,
    )
    signed = account.sign_typed_data(full_message=typed_data)
    r = int(signed.r).to_bytes(32, "big")
    s = int(signed.s).to_bytes(32, "big")
    return int(signed.v), r, s
