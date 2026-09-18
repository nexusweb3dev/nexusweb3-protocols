"""Python SDK for the NexusWeb3 v2 agent protocol contracts."""

from .addresses import BASE_ERC8004_IDENTITY_REGISTRY, Addresses, load_addresses
from .client import NexusClient
from .errors import ContractRevert, MissingSignerError, NexusError, TransactionFailed
from .permit import BASE_USDC_PERMIT_VERSION, build_permit_typed_data, sign_permit
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
    "BASE_USDC_PERMIT_VERSION",
    "ActionLog",
    "AgentConfig",
    "AgentProfile",
    "CreateParams",
    "Job",
    "JobStatus",
    "Milestone",
    "MilestoneStatus",
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
