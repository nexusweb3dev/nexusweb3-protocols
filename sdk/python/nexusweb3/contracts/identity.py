"""AgentIdentityV2 — free, permanent agent identity (`IAgentIdentityV2`)."""

from __future__ import annotations

from web3 import Web3

from ..tx import TxResult
from ..types import AgentProfile
from .base import Ownable2StepClient

__all__ = ["IdentityClient"]


class IdentityClient(Ownable2StepClient):
    """Writes are signed by the agent principal or one of its operators."""

    def register(self, agent: str, name: str, agent_uri: str, agent_type: int) -> TxResult:
        """Register `agent`. `name` may only hold lowercase `a-z`, digits, `-`, `_` and `.`.

        The narrow alphabet keeps two names that look alike from being different byte strings;
        anything outside it (uppercase, spaces, non-ASCII homoglyphs) reverts with `InvalidName`.
        """
        return self._send(
            "register", Web3.to_checksum_address(agent), name, agent_uri, int(agent_type)
        )

    def set_agent_uri(self, agent: str, agent_uri: str) -> TxResult:
        return self._send("setAgentURI", Web3.to_checksum_address(agent), agent_uri)

    def set_agent_type(self, agent: str, agent_type: int) -> TxResult:
        return self._send("setAgentType", Web3.to_checksum_address(agent), int(agent_type))

    def deactivate(self, agent: str) -> TxResult:
        return self._send("deactivate", Web3.to_checksum_address(agent))

    def reactivate(self, agent: str) -> TxResult:
        return self._send("reactivate", Web3.to_checksum_address(agent))

    def link_erc8004(self, agent: str, agent_id: int) -> TxResult:
        """Link an ERC-8004 agentId; the registry must report `agent` as its owner.

        `agent_id` must be non-zero: `0` reverts with `InvalidERC8004Id` instead of recording an
        empty link that would read back as "unlinked" anyway.
        """
        return self._send("linkERC8004", Web3.to_checksum_address(agent), int(agent_id))

    def unlink_erc8004(self, agent: str) -> TxResult:
        return self._send("unlinkERC8004", Web3.to_checksum_address(agent))

    def get_agent(self, agent: str) -> AgentProfile:
        return AgentProfile.from_tuple(self._call("getAgent", Web3.to_checksum_address(agent)))

    def is_registered(self, agent: str) -> bool:
        return bool(self._call("isRegistered", Web3.to_checksum_address(agent)))

    def get_agent_by_name(self, name: str) -> str:
        """Principal that owns `name`, or the zero address when it is free."""
        return str(self._call("getAgentByName", name))

    def erc8004_id_of(self, agent: str) -> int:
        """Linked ERC-8004 agentId; 0 when none, or when the link predates :meth:`registry_epoch`."""
        return int(self._call("erc8004IdOf", Web3.to_checksum_address(agent)))

    def agent_of_erc8004(self, agent_id: int) -> str:
        """Principal behind an agentId; the zero address when unlinked or from an older epoch."""
        return str(self._call("agentOfERC8004", int(agent_id)))

    def registry_epoch(self) -> int:
        """Bumped whenever the owner repoints the contract at another ERC-8004 registry.

        Links written under an earlier epoch read as absent, so swapping the registry cannot let a
        stale link inherit ownership in the new one.
        """
        return int(self._call("registryEpoch"))

    def agent_count(self) -> int:
        return int(self._call("agentCount"))

    def erc8004_registry(self) -> str:
        return str(self._call("erc8004Registry"))
