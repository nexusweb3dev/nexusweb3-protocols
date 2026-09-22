"""Timeout phases of the end-to-end run: `settleExpired` and cancelling an unaccepted offer.

Both exercise the post-audit rule that time, not silence, decides an escrow job: work that was
submitted vests to the provider, work that was never delivered comes back to the client, and an
offer nobody accepted is refunded in full.
"""

from __future__ import annotations

from nexusweb3 import CreateParams, JobStatus, MilestoneStatus, NexusClient, parse_usdc

from e2e_support import Checks, advance_time

SUBMITTED_USDC = "60"  # delivered before the job expires
PENDING_USDC = "40"  # never delivered
CANCEL_USDC = "90"  # refunded when the offer is cancelled
SUBMITTED_AMOUNT = parse_usdc(SUBMITTED_USDC)
PENDING_AMOUNT = parse_usdc(PENDING_USDC)
CANCEL_AMOUNT = parse_usdc(CANCEL_USDC)
#: Two days: short enough that the 8-day jump clears max(deadline, submittedAt + REVIEW_WINDOW).
SETTLE_DEADLINE_SECONDS = 2 * 24 * 3600
EXPIRY_SKIP = 8 * 24 * 3600


def _chain_now(client: NexusClient) -> int:
    return int(client.w3.eth.get_block("latest")["timestamp"])


def run_settle_phase(checks: Checks, clients: dict[str, NexusClient], provider: str) -> None:
    """Client goes silent after one submission; an unrelated third party settles the job."""
    client_op = clients["client_operator"]
    provider_op = clients["provider_operator"]
    client_address = clients["client_principal"].address

    params = CreateParams(
        client=client_address,
        provider=provider,
        milestone_amounts=[SUBMITTED_USDC, PENDING_USDC],
        deadline=_chain_now(client_op) + SETTLE_DEADLINE_SECONDS,
        terms_hash="PY_SDK_SETTLE_TERMS",
    )
    created = client_op.escrow.create_job(params)
    if created.job_id is None:
        checks.check("settle job created", False, "no JobCreated event")
        return
    job_id = created.job_id
    provider_op.escrow.accept_job(job_id)
    # Only the first milestone is delivered; the second must find its way back to the client.
    provider_op.escrow.submit_milestone(job_id, 0, "SETTLE_DELIVERABLE")

    provider_before = client_op.usdc.balance_of(provider)
    client_before = client_op.usdc.balance_of(client_address)
    advance_time(clients["bystander"].w3, EXPIRY_SKIP)

    result = clients["bystander"].escrow.settle_expired(job_id)
    provider_delta = client_op.usdc.balance_of(provider) - provider_before
    client_delta = client_op.usdc.balance_of(client_address) - client_before
    checks.check(
        "settleExpired by a third party pays the submitted milestone to the provider",
        provider_delta == SUBMITTED_AMOUNT and result.to_provider == SUBMITTED_AMOUNT,
        f"delta={provider_delta} event={result.to_provider} expected={SUBMITTED_AMOUNT}",
    )
    checks.check(
        "settleExpired refunds the pending milestone to the client",
        client_delta == PENDING_AMOUNT and result.to_client == PENDING_AMOUNT,
        f"delta={client_delta} event={result.to_client} expected={PENDING_AMOUNT}",
    )

    job = client_op.escrow.get_job(job_id)
    milestones = client_op.escrow.get_milestones(job_id)
    checks.check("settled job is Expired", job.status is JobStatus.EXPIRED, str(job.status))
    checks.check(
        "the submitted milestone vested, the pending one did not",
        milestones[0].status is MilestoneStatus.APPROVED
        and milestones[1].status is MilestoneStatus.PENDING,
        f"statuses={[m.status.value for m in milestones]}",
    )


def run_cancel_phase(checks: Checks, clients: dict[str, NexusClient], provider: str) -> None:
    """An offer the provider never accepted is cancellable for a full refund."""
    client_op = clients["client_operator"]
    client_address = clients["client_principal"].address

    balance_before = client_op.usdc.balance_of(client_address)
    params = CreateParams(
        client=client_address,
        provider=provider,
        milestone_amounts=[CANCEL_USDC],
        deadline=_chain_now(client_op) + 7 * 24 * 3600,
        terms_hash="PY_SDK_CANCEL_TERMS",
    )
    created = client_op.escrow.create_job(params)
    if created.job_id is None:
        checks.check("cancel job created", False, "no JobCreated event")
        return
    job_id = created.job_id

    offer = client_op.escrow.get_job(job_id)
    checks.check(
        "the offer is unaccepted and nothing was ever submitted",
        not offer.accepted and not offer.ever_submitted,
        f"acceptedAt={offer.accepted_at} everSubmitted={offer.ever_submitted}",
    )

    client_op.escrow.cancel_job(job_id)
    cancelled = client_op.escrow.get_job(job_id)
    balance_after = client_op.usdc.balance_of(client_address)
    checks.check(
        "cancel before acceptance refunds the client in full",
        cancelled.status is JobStatus.CANCELLED
        and cancelled.refunded == CANCEL_AMOUNT
        and balance_after == balance_before,
        f"status={cancelled.status.value} refunded={cancelled.refunded} netDelta={balance_after - balance_before}",
    )
