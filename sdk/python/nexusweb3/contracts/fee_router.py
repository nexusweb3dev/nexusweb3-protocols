"""FeeRouter — the single protocol fee sink (`IFeeRouter`)."""

from __future__ import annotations

from web3 import Web3

from ..tx import TxResult
from .base import Ownable2StepClient

__all__ = ["FeeRouterClient"]


class FeeRouterClient(Ownable2StepClient):
    """Fees are transferred to the router, then `route` splits them referral/staking/treasury.

    A referral sink that reverts does not fail the routing: the router emits `ReferralCallFailed`
    with the agent and the amount, and pays the whole fee to staking and treasury instead.
    """

    def route(self, agent: str, amount: int) -> TxResult:
        """Authorized protocols only: distribute `amount` already held by the router."""
        return self._send("route", Web3.to_checksum_address(agent), int(amount))

    def payment_token(self) -> str:
        return str(self._call("paymentToken"))

    def treasury(self) -> str:
        return str(self._call("treasury"))

    def staking_recipient(self) -> str:
        return str(self._call("stakingRecipient"))

    def referral(self) -> str:
        return str(self._call("referral"))

    def split(self) -> tuple[int, int]:
        """`(stakingBps, treasuryBps)`, summing to 10_000."""
        staking_bps, treasury_bps = self._call("split")
        return int(staking_bps), int(treasury_bps)

    def is_authorized_protocol(self, protocol: str) -> bool:
        return bool(self._call("isAuthorizedProtocol", Web3.to_checksum_address(protocol)))

    def set_split(self, staking_bps: int, treasury_bps: int) -> TxResult:
        return self._send("setSplit", int(staking_bps), int(treasury_bps))

    def set_recipients(self, treasury: str, staking_recipient: str) -> TxResult:
        return self._send(
            "setRecipients",
            Web3.to_checksum_address(treasury),
            Web3.to_checksum_address(staking_recipient),
        )

    def set_referral(self, referral: str) -> TxResult:
        return self._send("setReferral", Web3.to_checksum_address(referral))

    def authorize_protocol(self, protocol: str) -> TxResult:
        return self._send("authorizeProtocol", Web3.to_checksum_address(protocol))

    def revoke_protocol(self, protocol: str) -> TxResult:
        return self._send("revokeProtocol", Web3.to_checksum_address(protocol))
