"""AgentReputationV2 — value-weighted reputation (`IAgentReputationV2`)."""

from __future__ import annotations

from web3 import Web3

from ..amount import UsdcAmount, to_base_units
from ..tx import TxResult
from ..types import ReputationCategory, Stats, Tier
from .base import Ownable2StepClient

__all__ = ["ReputationClient"]

_TIERS: tuple[Tier, ...] = (Tier.BRONZE, Tier.SILVER, Tier.GOLD, Tier.PLATINUM)


class ReputationClient(Ownable2StepClient):
    """Reads are free; `record_interaction` is restricted to authorized protocols."""

    def record_interaction(
        self, agent: str, positive: bool, category: int | ReputationCategory, value_usdc: UsdcAmount
    ) -> TxResult:
        """`value_usdc` is a USDC figure in dollars, like every other amount in this SDK."""
        return self._send(
            "recordInteraction",
            Web3.to_checksum_address(agent),
            bool(positive),
            int(category),
            to_base_units(value_usdc, "value_usdc"),
        )

    def get_score(self, agent: str) -> int:
        return int(self._call("getScore", Web3.to_checksum_address(agent)))

    def get_tier(self, agent: str) -> Tier:
        index = int(self._call("getTier", Web3.to_checksum_address(agent)))
        if not 0 <= index < len(_TIERS):
            raise ValueError(f"unknown tier index {index}")
        return _TIERS[index]

    def get_stats(self, agent: str) -> Stats:
        return Stats.from_tuple(self._call("getStats", Web3.to_checksum_address(agent)))

    def is_authorized_protocol(self, protocol: str) -> bool:
        return bool(self._call("isAuthorizedProtocol", Web3.to_checksum_address(protocol)))

    def authorize_protocol(self, protocol: str) -> TxResult:
        return self._send("authorizeProtocol", Web3.to_checksum_address(protocol))

    def revoke_protocol(self, protocol: str) -> TxResult:
        return self._send("revokeProtocol", Web3.to_checksum_address(protocol))
