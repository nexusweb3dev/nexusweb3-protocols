"""Enums, struct dataclasses and bytes32 helpers for the v2 contracts."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Mapping, Sequence

from .amount import UsdcAmount, to_base_units

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ZERO_BYTES32 = b"\x00" * 32
MAX_UINT48 = (1 << 48) - 1

__all__ = [
    "ZERO_ADDRESS",
    "ZERO_BYTES32",
    "MAX_UINT48",
    "Tier",
    "JobStatus",
    "MilestoneStatus",
    "ReputationCategory",
    "AgentProfile",
    "Stats",
    "AgentConfig",
    "Job",
    "Milestone",
    "ActionLog",
    "CreateParams",
    "Payout",
    "to_bytes32",
    "from_bytes32",
    "coerce_bytes32",
]


class Tier(str, Enum):
    """`IAgentReputationV2.Tier` — ordered by the enum index on chain."""

    BRONZE = "BRONZE"
    SILVER = "SILVER"
    GOLD = "GOLD"
    PLATINUM = "PLATINUM"


class JobStatus(str, Enum):
    """`IAgentEscrowV2.JobStatus`."""

    OPEN = "Open"
    COMPLETED = "Completed"
    CANCELLED = "Cancelled"
    DISPUTED = "Disputed"
    RESOLVED = "Resolved"
    EXPIRED = "Expired"


class MilestoneStatus(str, Enum):
    """`IAgentEscrowV2.MilestoneStatus`."""

    PENDING = "Pending"
    SUBMITTED = "Submitted"
    APPROVED = "Approved"


class ReputationCategory(int, Enum):
    """`recordInteraction` category argument (0..4)."""

    PAYMENT = 0
    ESCROW = 1
    YIELD = 2
    INSURANCE = 3
    GENERAL = 4


def _by_index(enum_cls: type[Enum], index: int) -> Any:
    members = list(enum_cls)
    if not 0 <= index < len(members):
        raise ValueError(f"{enum_cls.__name__} index {index} out of range 0..{len(members) - 1}")
    return members[index]


def to_bytes32(value: str) -> bytes:
    """UTF-8 encode a short label into a right-padded bytes32 (solidity string literal layout)."""
    raw = value.encode("utf-8")
    if len(raw) > 32:
        raise ValueError(f"value is {len(raw)} bytes, bytes32 holds at most 32")
    return raw.ljust(32, b"\x00")


def from_bytes32(value: bytes) -> str:
    """Inverse of :func:`to_bytes32`; trailing zero padding is stripped."""
    if len(value) > 32:
        raise ValueError(f"expected at most 32 bytes, got {len(value)}")
    return bytes(value).rstrip(b"\x00").decode("utf-8")


def coerce_bytes32(value: str | bytes | bytearray | None) -> bytes:
    """Accept a label, a 0x-hex digest or raw bytes and return exactly 32 bytes."""
    if value is None:
        return ZERO_BYTES32
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        if len(raw) > 32:
            raise ValueError(f"expected at most 32 bytes, got {len(raw)}")
        return raw.rjust(32, b"\x00") if len(raw) < 32 else raw
    if value.startswith("0x") or value.startswith("0X"):
        raw = bytes.fromhex(value[2:])
        if len(raw) != 32:
            raise ValueError(f"hex bytes32 must be 32 bytes, got {len(raw)}")
        return raw
    return to_bytes32(value)


@dataclass(frozen=True)
class AgentProfile:
    """`IAgentIdentityV2.AgentProfile`."""

    name: str
    agent_uri: str
    agent_type: int
    registered_at: int
    updated_at: int
    active: bool

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "AgentProfile":
        return cls(
            name=values[0],
            agent_uri=values[1],
            agent_type=int(values[2]),
            registered_at=int(values[3]),
            updated_at=int(values[4]),
            active=bool(values[5]),
        )


@dataclass(frozen=True)
class Stats:
    """`IAgentReputationV2.Stats`."""

    positives: int
    negatives: int
    volume_usdc: int
    first_seen: int
    last_activity: int

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "Stats":
        return cls(
            positives=int(values[0]),
            negatives=int(values[1]),
            volume_usdc=int(values[2]),
            first_seen=int(values[3]),
            last_activity=int(values[4]),
        )


@dataclass(frozen=True)
class AgentConfig:
    """`IAgentKillSwitchV2.AgentConfig`."""

    spending_limit: int
    spent: int
    tx_limit: int
    tx_count: int
    session_duration: int
    session_start: int
    registered: bool
    killed: bool
    paused: bool

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "AgentConfig":
        return cls(
            spending_limit=int(values[0]),
            spent=int(values[1]),
            tx_limit=int(values[2]),
            tx_count=int(values[3]),
            session_duration=int(values[4]),
            session_start=int(values[5]),
            registered=bool(values[6]),
            killed=bool(values[7]),
            paused=bool(values[8]),
        )


@dataclass(frozen=True)
class Job:
    """`IAgentEscrowV2.Job`."""

    client: str
    provider: str
    arbiter: str
    total: int
    released: int
    refunded: int
    deadline: int
    created_at: int
    accepted_at: int
    disputed_at: int
    milestone_count: int
    approved_count: int
    ever_submitted: bool
    status: JobStatus
    terms_hash: bytes

    @property
    def accepted(self) -> bool:
        """True once the provider bound itself to the offer with `acceptJob`."""
        return self.accepted_at != 0

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "Job":
        return cls(
            client=values[0],
            provider=values[1],
            arbiter=values[2],
            total=int(values[3]),
            released=int(values[4]),
            refunded=int(values[5]),
            deadline=int(values[6]),
            created_at=int(values[7]),
            accepted_at=int(values[8]),
            disputed_at=int(values[9]),
            milestone_count=int(values[10]),
            approved_count=int(values[11]),
            ever_submitted=bool(values[12]),
            status=_by_index(JobStatus, int(values[13])),
            terms_hash=bytes(values[14]),
        )


@dataclass(frozen=True)
class Milestone:
    """`IAgentEscrowV2.Milestone`."""

    amount: int
    deliverable_hash: bytes
    submitted_at: int
    rejections: int
    status: MilestoneStatus

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "Milestone":
        return cls(
            amount=int(values[0]),
            deliverable_hash=bytes(values[1]),
            submitted_at=int(values[2]),
            rejections=int(values[3]),
            status=_by_index(MilestoneStatus, int(values[4])),
        )


@dataclass(frozen=True)
class Payout:
    """One payout attempt, decoded from `IAgentEscrowV2.PayoutSettled`.

    A transfer that fails — a blacklisted recipient, a token that returns false — never blocks a
    job: the escrow parks the amount as claimable for `account` instead, recoverable later with
    `withdraw_claimable`. Both outcomes leave the transaction successful, so :attr:`delivered` is
    the only way to tell them apart without re-reading the chain.
    """

    account: str
    #: Base units moved, net of protocol fee where a fee applied.
    amount: int
    #: True when the tokens reached `account`; False when they were parked as claimable.
    delivered: bool

    @classmethod
    def from_args(cls, args: Mapping[str, Any]) -> "Payout":
        return cls(
            account=str(args["account"]),
            amount=int(args["amount"]),
            delivered=bool(args["delivered"]),
        )


@dataclass(frozen=True)
class ActionLog:
    """`IAgentAuditLogV2.ActionLog`."""

    agent: str
    caller: str
    action_type: bytes
    data_hash: bytes
    value: int
    timestamp: int
    block_number: int

    @property
    def action_label(self) -> str:
        """The action type decoded back to text, or its hex form when it is not UTF-8."""
        try:
            return from_bytes32(self.action_type)
        except UnicodeDecodeError:
            return "0x" + self.action_type.hex()

    @classmethod
    def from_tuple(cls, values: Sequence[Any]) -> "ActionLog":
        return cls(
            agent=values[0],
            caller=values[1],
            action_type=bytes(values[2]),
            data_hash=bytes(values[3]),
            value=int(values[4]),
            timestamp=int(values[5]),
            block_number=int(values[6]),
        )


@dataclass(frozen=True)
class CreateParams:
    """`IAgentEscrowV2.CreateParams`.

    `milestone_amounts` are USDC figures in dollars (``["100", "150.50"]``); pass ints only when
    you already hold base units. :meth:`base_unit_amounts` and :attr:`total` do the conversion.
    """

    client: str
    provider: str
    milestone_amounts: Sequence[UsdcAmount]
    deadline: int
    arbiter: str = ZERO_ADDRESS
    terms_hash: bytes = ZERO_BYTES32

    def base_unit_amounts(self) -> list[int]:
        """The milestone amounts in base units, in order."""
        amounts = [
            to_base_units(a, f"milestone_amounts[{i}]") for i, a in enumerate(self.milestone_amounts)
        ]
        if not amounts:
            raise ValueError("at least one milestone amount is required")
        return amounts

    def to_tuple(self) -> tuple[str, str, str, list[int], int, bytes]:
        """Solidity struct ordering for web3 encoding."""
        return (
            self.client,
            self.provider,
            self.arbiter,
            self.base_unit_amounts(),
            int(self.deadline),
            coerce_bytes32(self.terms_hash),
        )

    @property
    def total(self) -> int:
        """Sum of the milestones, in base units."""
        return sum(self.base_unit_amounts())
