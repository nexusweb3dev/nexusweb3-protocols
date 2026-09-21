"""Per-contract sub-clients used by :class:`nexusweb3.client.NexusClient`."""

from .access import AccessClient
from .audit_log import AuditLogClient
from .base import ContractClient
from .erc20 import ERC20Client
from .escrow import EscrowClient
from .fee_router import FeeRouterClient
from .identity import IdentityClient
from .kill_switch import KillSwitchClient
from .reputation import ReputationClient

__all__ = [
    "AccessClient",
    "AuditLogClient",
    "ContractClient",
    "ERC20Client",
    "EscrowClient",
    "FeeRouterClient",
    "IdentityClient",
    "KillSwitchClient",
    "ReputationClient",
]
