"""AgentAccess — the operator registry (`IAgentAccess`)."""

from __future__ import annotations

from web3 import Web3

from ..tx import TxResult
from ..types import MAX_UINT48
from .base import ContractClient

__all__ = ["AccessClient"]


class AccessClient(ContractClient):
    """Principals authorize hot operator keys here; every other v2 contract reads this registry."""

    #: `type(uint48).max` — an authorization that never expires.
    NO_EXPIRY = MAX_UINT48

    def authorize_operator(self, operator: str, expiry: int = MAX_UINT48) -> TxResult:
        """Let `operator` act for the signing principal until `expiry` (unix seconds)."""
        return self._send("authorizeOperator", Web3.to_checksum_address(operator), int(expiry))

    def revoke_operator(self, operator: str) -> TxResult:
        return self._send("revokeOperator", Web3.to_checksum_address(operator))

    def renounce_operator(self, agent: str) -> TxResult:
        """Signed by the operator itself: give up its own authorization for `agent`.

        Lets a hot key that may have leaked cut itself off without waiting for the principal.
        """
        return self._send("renounceOperator", Web3.to_checksum_address(agent))

    def is_operator_for(self, agent: str, caller: str) -> bool:
        return bool(
            self._call("isOperatorFor", Web3.to_checksum_address(agent), Web3.to_checksum_address(caller))
        )

    def operator_expiry(self, agent: str, operator: str) -> int:
        """Expiry of the authorization, 0 when not authorized."""
        return int(
            self._call("operatorExpiry", Web3.to_checksum_address(agent), Web3.to_checksum_address(operator))
        )
