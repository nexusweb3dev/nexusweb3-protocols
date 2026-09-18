"""`NexusClient` — one entry point onto a deployed v2 stack."""

from __future__ import annotations

from typing import Optional

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3

from .abi import ERC20_ABI, load_abi
from .addresses import Addresses, load_addresses
from .contracts import (
    AccessClient,
    AuditLogClient,
    ERC20Client,
    EscrowClient,
    FeeRouterClient,
    IdentityClient,
    KillSwitchClient,
    ReputationClient,
)
from .tx import TxSender

__all__ = ["NexusClient"]


class NexusClient:
    """Namespaced access to the v2 contracts.

    ``access``, ``identity``, ``reputation``, ``kill_switch``, ``audit_log``, ``escrow``, ``fee_router``
    and ``usdc`` each mirror one interface. Reads work without an account; writes need one.
    """

    def __init__(self, w3: Web3, addresses: Addresses, account: Optional[LocalAccount] = None) -> None:
        self._w3 = w3
        self._addresses = addresses
        self._sender = TxSender(w3, account)

        self.access = AccessClient(w3, addresses.access, load_abi("AgentAccess"), self._sender)
        self.identity = IdentityClient(w3, addresses.identity, load_abi("AgentIdentityV2"), self._sender)
        self.reputation = ReputationClient(
            w3, addresses.reputation, load_abi("AgentReputationV2"), self._sender
        )
        self.kill_switch = KillSwitchClient(
            w3, addresses.kill_switch, load_abi("AgentKillSwitchV2"), self._sender
        )
        self.audit_log = AuditLogClient(w3, addresses.audit_log, load_abi("AgentAuditLogV2"), self._sender)
        self.escrow = EscrowClient(w3, addresses.escrow, load_abi("AgentEscrowV2"), self._sender)
        self.fee_router = FeeRouterClient(w3, addresses.fee_router, load_abi("FeeRouter"), self._sender)
        self.usdc = ERC20Client(w3, addresses.payment_token, ERC20_ABI, self._sender)

    # ─── Construction helpers ───────────────────────────────────────────
    @classmethod
    def from_rpc(
        cls,
        rpc_url: str,
        addresses: Addresses | str | dict[str, str],
        private_key: str | None = None,
        *,
        request_timeout: float = 30.0,
    ) -> "NexusClient":
        """Build a client from an RPC URL, a deployment file (or mapping) and an optional key."""
        w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": request_timeout}))
        resolved = addresses if isinstance(addresses, Addresses) else load_addresses(addresses)
        account = Account.from_key(private_key) if private_key else None
        return cls(w3, resolved, account)

    # ─── Properties ─────────────────────────────────────────────────────
    @property
    def w3(self) -> Web3:
        return self._w3

    @property
    def addresses(self) -> Addresses:
        return self._addresses

    @property
    def account(self) -> Optional[LocalAccount]:
        return self._sender.account

    @property
    def address(self) -> str:
        """Address of the signing account. Raises when the client is read-only."""
        return self._sender.address

    @property
    def chain_id(self) -> int:
        return int(self._w3.eth.chain_id)

    def is_connected(self) -> bool:
        return bool(self._w3.is_connected())
