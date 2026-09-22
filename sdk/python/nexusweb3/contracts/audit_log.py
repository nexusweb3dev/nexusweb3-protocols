"""AgentAuditLogV2 — append-only per-agent action log (`IAgentAuditLogV2`)."""

from __future__ import annotations

from typing import Sequence

from web3 import Web3

from ..tx import TxResult
from ..types import ActionLog, coerce_bytes32
from .base import Ownable2StepClient

__all__ = ["AuditLogClient"]


class AuditLogClient(Ownable2StepClient):
    """`action_type` and `data_hash` accept a short label, a 0x-hex digest or raw bytes."""

    def max_page_size(self) -> int:
        """Entries one `get_agent_logs` page returns at most; larger `limit` values are clipped."""
        return int(self._call("MAX_PAGE_SIZE"))

    def log(
        self,
        agent: str,
        action_type: str | bytes,
        data_hash: str | bytes,
        value: int = 0,
    ) -> TxResult:
        """Append one entry. The returned :class:`TxResult` carries the assigned `log_id`."""
        result = self._send(
            "log",
            Web3.to_checksum_address(agent),
            coerce_bytes32(action_type),
            coerce_bytes32(data_hash),
            int(value),
        )
        log_id = self._first_event_arg("ActionLogged", result.receipt, "logId")
        return TxResult(hash=result.hash, receipt=result.receipt, log_id=log_id)

    def log_batch(
        self,
        agent: str,
        action_types: Sequence[str | bytes],
        data_hashes: Sequence[str | bytes],
        values: Sequence[int],
    ) -> TxResult:
        """Append several entries; `log_id` on the result is the first assigned id."""
        if not (len(action_types) == len(data_hashes) == len(values)):
            raise ValueError("action_types, data_hashes and values must have the same length")
        result = self._send(
            "logBatch",
            Web3.to_checksum_address(agent),
            [coerce_bytes32(a) for a in action_types],
            [coerce_bytes32(h) for h in data_hashes],
            [int(v) for v in values],
        )
        log_id = self._first_event_arg("ActionLogged", result.receipt, "logId")
        return TxResult(hash=result.hash, receipt=result.receipt, log_id=log_id)

    def get_log(self, log_id: int) -> ActionLog:
        return ActionLog.from_tuple(self._call("getLog", int(log_id)))

    def get_log_count(self, agent: str) -> int:
        return int(self._call("getLogCount", Web3.to_checksum_address(agent)))

    def get_agent_logs(self, agent: str, offset: int = 0, limit: int = 50) -> list[ActionLog]:
        rows = self._call("getAgentLogs", Web3.to_checksum_address(agent), int(offset), int(limit))
        return [ActionLog.from_tuple(row) for row in rows]

    def total_logs(self) -> int:
        return int(self._call("totalLogs"))

    def is_authorized_protocol(self, protocol: str) -> bool:
        return bool(self._call("isAuthorizedProtocol", Web3.to_checksum_address(protocol)))

    def authorize_protocol(self, protocol: str) -> TxResult:
        return self._send("authorizeProtocol", Web3.to_checksum_address(protocol))

    def revoke_protocol(self, protocol: str) -> TxResult:
        return self._send("revokeProtocol", Web3.to_checksum_address(protocol))
