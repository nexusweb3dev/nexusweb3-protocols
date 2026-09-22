"""Python SDK for the NexusWeb3 v2 agent protocol contracts."""

from .addresses import BASE_ERC8004_IDENTITY_REGISTRY, Addresses, load_addresses
from .amount import USDC_DECIMALS, UsdcAmount, format_usdc, parse_usdc, to_base_units
from .client import NexusClient
from .errors import ContractRevert, MissingSignerError, NexusError, TransactionFailed
from .permit import (
    BASE_USDC_PERMIT_VERSION,
    DEFAULT_PERMIT_VERSION,
    KNOWN_PERMIT_VERSIONS,
    build_permit_typed_data,
    resolve_permit_version,
    sign_permit,
)
from .tx import TxResult
from .types import (
    MAX_UINT48,
    ZERO_ADDRESS,
    ZERO_BYTES32,
    ActionLog,
    AgentConfig,
    AgentProfile,
    CreateParams,
    Job,
    JobStatus,
    Milestone,
    MilestoneStatus,
    Payout,
    ReputationCategory,
    Stats,
    Tier,
    coerce_bytes32,
    from_bytes32,
    to_bytes32,
)

__version__ = "2.0.0"

__all__ = [
    "__version__",
    "Addresses",
    "load_addresses",
    "BASE_ERC8004_IDENTITY_REGISTRY",
    "NexusClient",
    "NexusError",
    "MissingSignerError",
    "ContractRevert",
    "TransactionFailed",
    "TxResult",
    "sign_permit",
    "build_permit_typed_data",
    "resolve_permit_version",
    "BASE_USDC_PERMIT_VERSION",
    "DEFAULT_PERMIT_VERSION",
    "KNOWN_PERMIT_VERSIONS",
    "USDC_DECIMALS",
    "UsdcAmount",
    "parse_usdc",
    "format_usdc",
    "to_base_units",
    "ActionLog",
    "AgentConfig",
    "AgentProfile",
    "CreateParams",
    "Job",
    "JobStatus",
    "Milestone",
    "MilestoneStatus",
    "Payout",
    "ReputationCategory",
    "Stats",
    "Tier",
    "to_bytes32",
    "from_bytes32",
    "coerce_bytes32",
    "ZERO_ADDRESS",
    "ZERO_BYTES32",
    "MAX_UINT48",
]
