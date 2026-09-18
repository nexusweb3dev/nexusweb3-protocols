"""AgentEscrowV2 — milestone escrow (`IAgentEscrowV2`)."""

from __future__ import annotations

from web3 import Web3

from ..tx import TxResult
from ..types import CreateParams, Job, Milestone, coerce_bytes32
from .base import ContractClient

__all__ = ["EscrowClient"]


class EscrowClient(ContractClient):
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
        """Pay the provider for milestone `index` (minus fee) and advance the job."""
        return self._send("approveMilestone", int(job_id), int(index))

    def reject_milestone(self, job_id: int, index: int, reason_hash: str | bytes | None = None) -> TxResult:
        return self._send("rejectMilestone", int(job_id), int(index), coerce_bytes32(reason_hash))

    def cancel_job(self, job_id: int) -> TxResult:
        return self._send("cancelJob", int(job_id))

    # ─── Provider ───────────────────────────────────────────────────────
    def submit_milestone(self, job_id: int, index: int, deliverable_hash: str | bytes) -> TxResult:
        return self._send("submitMilestone", int(job_id), int(index), coerce_bytes32(deliverable_hash))

    def claim_approval(self, job_id: int, index: int) -> TxResult:
        """Provider self-approval of a milestone the client left Submitted past `REVIEW_WINDOW`."""
        return self._send("claimApproval", int(job_id), int(index))

    # ─── Either party / arbiter / anyone ────────────────────────────────
    def dispute(self, job_id: int, reason_hash: str | bytes | None = None) -> TxResult:
        return self._send("dispute", int(job_id), coerce_bytes32(reason_hash))

    def resolve(self, job_id: int, provider_bps: int) -> TxResult:
        """Arbiter only: split the remaining funds, `provider_bps` out of 10_000 to the provider."""
        return self._send("resolve", int(job_id), int(provider_bps))

    def refund_expired(self, job_id: int) -> TxResult:
        return self._send("refundExpired", int(job_id))

    def withdraw_claimable(self) -> TxResult:
        return self._send("withdrawClaimable")

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
        """Effective expiry: `max(deadline, latest submission + REVIEW_WINDOW)`."""
        return int(self._call("expiryOf", int(job_id)))

    def review_window(self) -> int:
        """Seconds a client may leave a submitted milestone unreviewed before the provider can claim."""
        return int(self._call("REVIEW_WINDOW"))

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

    def _with_job_id(self, result: TxResult) -> TxResult:
        job_id = self._first_event_arg("JobCreated", result.receipt, "jobId")
        return TxResult(hash=result.hash, receipt=result.receipt, job_id=job_id)
