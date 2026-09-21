"""AgentKillSwitchV2 — opt-in spending guard (`IAgentKillSwitchV2`)."""

from __future__ import annotations

from web3 import Web3

from ..tx import TxResult
from ..types import AgentConfig
from .base import ContractClient

__all__ = ["KillSwitchClient"]


class KillSwitchClient(ContractClient):
    """Config writes are principal-only; kill/pause also accept the configured guardian."""

    def register(self, spending_limit: int, tx_limit: int, session_duration: int) -> TxResult:
        """Opt in. `spending_limit` is in 6-decimal USDC units, `tx_limit` 0 means unlimited."""
        return self._send("register", int(spending_limit), int(tx_limit), int(session_duration))

    def set_limits(self, spending_limit: int, tx_limit: int, session_duration: int) -> TxResult:
        return self._send("setLimits", int(spending_limit), int(tx_limit), int(session_duration))

    def set_guardian(self, guardian: str) -> TxResult:
        return self._send("setGuardian", Web3.to_checksum_address(guardian))

    def resume(self) -> TxResult:
        """Un-kill the signing principal's agent."""
        return self._send("resume")

    def kill(self, agent: str) -> TxResult:
        return self._send("kill", Web3.to_checksum_address(agent))

    def pause(self, agent: str) -> TxResult:
        return self._send("pause", Web3.to_checksum_address(agent))

    def unpause(self, agent: str) -> TxResult:
        return self._send("unpause", Web3.to_checksum_address(agent))

    def reset_session(self, agent: str) -> TxResult:
        return self._send("resetSession", Web3.to_checksum_address(agent))

    def consume(self, agent: str, amount: int) -> TxResult:
        """Authorized protocols only: charge `amount` against the agent's session budget."""
        return self._send("consume", Web3.to_checksum_address(agent), int(amount))

    def is_active(self, agent: str) -> bool:
        return bool(self._call("isActive", Web3.to_checksum_address(agent)))

    def get_config(self, agent: str) -> AgentConfig:
        return AgentConfig.from_tuple(self._call("getConfig", Web3.to_checksum_address(agent)))

    def remaining_spend(self, agent: str) -> int:
        """Budget left this session; `2**256 - 1` for unregistered agents."""
        return int(self._call("remainingSpend", Web3.to_checksum_address(agent)))

    def guardian_of(self, agent: str) -> str:
        return str(self._call("guardianOf", Web3.to_checksum_address(agent)))

    def is_authorized_protocol(self, protocol: str) -> bool:
        return bool(self._call("isAuthorizedProtocol", Web3.to_checksum_address(protocol)))

    def authorize_protocol(self, protocol: str) -> TxResult:
        return self._send("authorizeProtocol", Web3.to_checksum_address(protocol))

    def revoke_protocol(self, protocol: str) -> TxResult:
        return self._send("revokeProtocol", Web3.to_checksum_address(protocol))
