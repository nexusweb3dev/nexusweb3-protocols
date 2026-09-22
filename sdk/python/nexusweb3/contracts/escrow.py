"""AgentEscrowV2 — milestone escrow (`IAgentEscrowV2`)."""

from __future__ import annotations

from dataclasses import replace

from web3 import Web3

from ..tx import TxResult
from ..types import CreateParams, Job, Milestone, Payout, coerce_bytes32
from .base import Ownable2StepClient

__all__ = ["EscrowClient"]


class EscrowClient(Ownable2StepClient):
    """Client and provider may act through their principals or their operators."""

    # ─── Client ─────────────────────────────────────────────────────────
    def create_job(self, params: CreateParams) -> TxResult:
        """Pull `params.total` from the client principal. Needs a prior USDC approval."""
        result = self._send("createJob", params.to_tuple())
        return self._with_job_id(result)

    def create_job_with_permit(
        self,
        params: CreateParams,
        permit_deadline: int,
        v: int,
        r: bytes,
        s: bytes,
    ) -> TxResult:
        """Create a job using an EIP-2612 signature instead of a prior approval.

        The contract calls `permit` inside a try/catch, so a token without EIP-2612 support
        fails later on `transferFrom` rather than here. Use :func:`nexusweb3.permit.sign_permit`.
        """
        result = self._send(
            "createJobWithPermit", params.to_tuple(), int(permit_deadline), int(v), bytes(r), bytes(s)
        )
        return self._with_job_id(result)

    def approve_milestone(self, job_id: int, index: int) -> TxResult:
        """Pay the provider for milestone `index` (minus fee) and advance the job.

        The returned :class:`TxResult` carries `payouts` decoded from `PayoutSettled`.
        """
        return self._with_payouts(self._send("approveMilestone", int(job_id), int(index)))

    def reject_milestone(self, job_id: int, index: int, reason_hash: str | bytes | None = None) -> TxResult:
        """Send a Submitted milestone back, inside `REVIEW_WINDOW` and at most `MAX_REJECTIONS` times."""
        return self._send("rejectMilestone", int(job_id), int(index), coerce_bytes32(reason_hash))

    def cancel_job(self, job_id: int) -> TxResult:
        """Full refund. Allowed before acceptance, and after it only while nothing was ever submitted.

        The returned :class:`TxResult` carries `payouts` decoded from `PayoutSettled`.
        """
        return self._with_payouts(self._send("cancelJob", int(job_id)))

    # ─── Provider ───────────────────────────────────────────────────────
    def accept_job(self, job_id: int) -> TxResult:
        """Bind the provider to the offer.

        A created job is only an offer: `submit_milestone`, `approve_milestone` and `dispute` all
        revert with `NotAccepted` until this lands, and the client may cancel for a full refund.
        Must happen before the job deadline, and only once (`AlreadyAccepted` afterwards).
        """
        return self._send("acceptJob", int(job_id))

    def submit_milestone(self, job_id: int, index: int, deliverable_hash: str | bytes) -> TxResult:
        return self._send("submitMilestone", int(job_id), int(index), coerce_bytes32(deliverable_hash))

    def claim_approval(self, job_id: int, index: int) -> TxResult:
        """Provider self-approval of a milestone the client left Submitted past `REVIEW_WINDOW`.

        The returned :class:`TxResult` carries `payouts` decoded from `PayoutSettled`.
        """
        return self._with_payouts(self._send("claimApproval", int(job_id), int(index)))

    # ─── Either party / arbiter / anyone ────────────────────────────────
    def dispute(self, job_id: int, reason_hash: str | bytes | None = None) -> TxResult:
        return self._send("dispute", int(job_id), coerce_bytes32(reason_hash))

    def resolve(self, job_id: int, provider_bps: int) -> TxResult:
        """Arbiter only: split the remaining funds, `provider_bps` out of 10_000 to the provider.

        The returned :class:`TxResult` carries `payouts` decoded from `PayoutSettled`.
        """
        return self._with_payouts(self._send("resolve", int(job_id), int(provider_bps)))

    def settle_expired(self, job_id: int) -> TxResult:
        """Anyone: close out a job time has decided.

        Open jobs qualify past `expiry_of`, Disputed ones `DISPUTE_GRACE` after `disputed_at`.
        Every Submitted milestone vests to the provider and every Pending one refunds the client,
        so client silence no longer claws back delivered work. The returned :class:`TxResult`
        carries `to_provider` and `to_client` decoded from `JobExpired`, plus `payouts`.
        """
        result = self._with_payouts(self._send("settleExpired", int(job_id)))
        args = self._event_args("JobExpired", result.receipt)
        if not args:
            return result
        return replace(
            result, to_provider=int(args[0]["toProvider"]), to_client=int(args[0]["toClient"])
        )

    def withdraw_claimable(self, account: str, to: str) -> TxResult:
        """Sweep funds parked for `account` after a failed payout into `to`.

        Signed by `account` itself or one of its operators; `to` must not be the zero address.
        The returned :class:`TxResult` carries `withdrawn` decoded from `ClaimableWithdrawn`.
        """
        result = self._send(
            "withdrawClaimable", Web3.to_checksum_address(account), Web3.to_checksum_address(to)
        )
        args = self._event_args("ClaimableWithdrawn", result.receipt)
        if not args:
            return result
        return replace(result, withdrawn=int(args[0]["amount"]))

    # ─── Views ──────────────────────────────────────────────────────────
    def get_job(self, job_id: int) -> Job:
        return Job.from_tuple(self._call("getJob", int(job_id)))

    def get_milestones(self, job_id: int) -> list[Milestone]:
        return [Milestone.from_tuple(row) for row in self._call("getMilestones", int(job_id))]

    def get_jobs_of(self, account: str, offset: int = 0, limit: int = 50) -> list[int]:
        rows = self._call("getJobsOf", Web3.to_checksum_address(account), int(offset), int(limit))
        return [int(job_id) for job_id in rows]

    def job_count_of(self, account: str) -> int:
        return int(self._call("jobCountOf", Web3.to_checksum_address(account)))

    def job_count(self) -> int:
        return int(self._call("jobCount"))

    def expiry_of(self, job_id: int) -> int:
        """Effective expiry: `max(deadline, latest submission + REVIEW_WINDOW)`.

        The moment an Open job becomes settleable with :meth:`settle_expired`, and the moment
        `dispute` stops working.
        """
        return int(self._call("expiryOf", int(job_id)))

    def review_window(self) -> int:
        """Seconds a client may leave a submitted milestone unreviewed before the provider can claim."""
        return int(self._call("REVIEW_WINDOW"))

    def dispute_grace(self) -> int:
        """Seconds a Disputed job waits for its arbiter before anyone may :meth:`settle_expired` it."""
        return int(self._call("DISPUTE_GRACE"))

    def max_rejections(self) -> int:
        """Rejections one milestone tolerates before resubmission reverts with `TooManyRejections`."""
        return int(self._call("MAX_REJECTIONS"))

    def max_reputation_per_pair(self) -> int:
        """Reputation entries a single client/provider pair may generate, so a pair cannot farm score."""
        return int(self._call("MAX_REPUTATION_PER_PAIR"))

    def min_reputation_value(self) -> int:
        """Settlement value below which no reputation is written, so dust jobs cannot farm score."""
        return int(self._call("MIN_REPUTATION_VALUE"))

    def claimable(self, account: str) -> int:
        return int(self._call("claimable", Web3.to_checksum_address(account)))

    def fee_bps(self) -> int:
        return int(self._call("feeBps"))

    def payment_token(self) -> str:
        return str(self._call("paymentToken"))

    def reputation(self) -> str:
        return str(self._call("reputation"))

    def audit_log(self) -> str:
        return str(self._call("auditLog"))

    def kill_switch(self) -> str:
        return str(self._call("killSwitch"))

    def fee_router(self) -> str:
        return str(self._call("feeRouter"))

    # ─── Owner ──────────────────────────────────────────────────────────
    def set_fee_bps(self, new_bps: int) -> TxResult:
        return self._send("setFeeBps", int(new_bps))

    def set_modules(self, reputation: str, audit_log: str, kill_switch: str, fee_router: str) -> TxResult:
        return self._send(
            "setModules",
            Web3.to_checksum_address(reputation),
            Web3.to_checksum_address(audit_log),
            Web3.to_checksum_address(kill_switch),
            Web3.to_checksum_address(fee_router),
        )

    def _with_payouts(self, result: TxResult) -> TxResult:
        """Attach every `PayoutSettled` this transaction emitted, in log order.

        The event fires for a delivered transfer and for one that bounced into `claimable` alike,
        so a caller can see where the money actually went without a second round trip.
        """
        payouts = tuple(
            Payout.from_args(args) for args in self._event_args("PayoutSettled", result.receipt)
        )
        return replace(result, payouts=payouts)

    def _with_job_id(self, result: TxResult) -> TxResult:
        job_id = self._first_event_arg("JobCreated", result.receipt, "jobId")
        return TxResult(hash=result.hash, receipt=result.receipt, job_id=job_id)
