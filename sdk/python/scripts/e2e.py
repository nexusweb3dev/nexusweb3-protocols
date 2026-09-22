#!/usr/bin/env python3
"""End-to-end run of the Python SDK against a local anvil deployment.

    anvil --port 8546 --silent &
    PRIVATE_KEY=<anvil key 0> DEPLOY_JSON_PATH=deployments/v2-local-py.json \\
        forge script script/v2/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
    python scripts/e2e.py

Env: RPC_URL (default http://127.0.0.1:8546), ADDRESSES_JSON (default ../../deployments/v2-local-py.json).
Exits non-zero if any check fails.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from web3 import Web3

from nexusweb3 import (
    CreateParams,
    JobStatus,
    MilestoneStatus,
    NexusClient,
    format_usdc,
    load_addresses,
    parse_usdc,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_permit import run_permit_phase  # noqa: E402
from e2e_support import Checks, anvil_account  # noqa: E402
from e2e_timeouts import run_cancel_phase, run_settle_phase  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
RPC_URL = os.environ.get("RPC_URL", "http://127.0.0.1:8546")
ADDRESSES_JSON = os.environ.get("ADDRESSES_JSON", str(REPO_ROOT / "deployments" / "v2-local-py.json"))

CLIENT_PRINCIPAL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CLIENT_OPERATOR_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
PROVIDER_PRINCIPAL_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
PROVIDER_OPERATOR_KEY = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
PERMIT_CLIENT_KEY = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
# anvil #5: an unrelated account that settles an expired job. Holds no USDC, only gas.
BYSTANDER_KEY = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"

# Amounts go in as USDC figures, the way every surface of the SDK takes them; the base-unit
# twins exist only to assert against balances, which the chain reports in base units.
MILESTONE_ONE_USDC = "100"
MILESTONE_TWO_USDC = "150.50"
BUDGET_USDC = "2500"
MILESTONE_ONE = parse_usdc(MILESTONE_ONE_USDC)
MILESTONE_TWO = parse_usdc(MILESTONE_TWO_USDC)
JOB_TOTAL = MILESTONE_ONE + MILESTONE_TWO


def _clients(w3: Web3, addresses_path: str) -> dict[str, NexusClient]:
    addresses = load_addresses(addresses_path)
    return {
        "client_principal": NexusClient(w3, addresses, anvil_account(CLIENT_PRINCIPAL_KEY)),
        "client_operator": NexusClient(w3, addresses, anvil_account(CLIENT_OPERATOR_KEY)),
        "provider_principal": NexusClient(w3, addresses, anvil_account(PROVIDER_PRINCIPAL_KEY)),
        "provider_operator": NexusClient(w3, addresses, anvil_account(PROVIDER_OPERATOR_KEY)),
        "bystander": NexusClient(w3, addresses, anvil_account(BYSTANDER_KEY)),
    }


def _authorize_operators(checks: Checks, clients: dict[str, NexusClient]) -> None:
    client_op = clients["client_operator"].address
    provider_op = clients["provider_operator"].address
    clients["client_principal"].access.authorize_operator(client_op)
    clients["provider_principal"].access.authorize_operator(provider_op)
    checks.check(
        "client operator authorized",
        clients["client_principal"].access.is_operator_for(clients["client_principal"].address, client_op),
    )
    checks.check(
        "provider operator authorized",
        clients["provider_principal"].access.is_operator_for(
            clients["provider_principal"].address, provider_op
        ),
    )


def _approve_usdc(checks: Checks, clients: dict[str, NexusClient]) -> None:
    escrow = clients["client_principal"].addresses.escrow
    for role in ("client_principal", "provider_principal"):
        client = clients[role]
        client.usdc.approve(escrow, BUDGET_USDC)
        allowance = client.usdc.allowance(client.address, escrow)
        checks.check(f"{role} approved USDC", allowance >= JOB_TOTAL, f"allowance={allowance}")


def _register_identities(checks: Checks, clients: dict[str, NexusClient]) -> None:
    suffix = str(int(time.time()))[-6:]
    pairs = (
        ("client_operator", "client_principal", f"py-client-{suffix}", 1),
        ("provider_operator", "provider_principal", f"py-provider-{suffix}", 2),
    )
    for operator_role, principal_role, name, agent_type in pairs:
        operator = clients[operator_role]
        principal = clients[principal_role].address
        if not operator.identity.is_registered(principal):
            operator.identity.register(principal, name, f"ipfs://{name}", agent_type)
        profile = operator.identity.get_agent(principal)
        checks.check(
            f"{principal_role} identity registered by its operator",
            operator.identity.is_registered(principal) and profile.active,
            f"name={profile.name} type={profile.agent_type}",
        )


def _chain_now(client: NexusClient) -> int:
    """Chain time, not wall-clock time: anvil may be ahead after evm_increaseTime."""
    return int(client.w3.eth.get_block("latest")["timestamp"])


def _create_job(checks: Checks, clients: dict[str, NexusClient]) -> int:
    params = CreateParams(
        client=clients["client_principal"].address,
        provider=clients["provider_principal"].address,
        milestone_amounts=[MILESTONE_ONE_USDC, MILESTONE_TWO_USDC],
        deadline=_chain_now(clients["client_operator"]) + 7 * 24 * 3600,
        terms_hash="PY_SDK_E2E_TERMS",
    )
    result = clients["client_operator"].escrow.create_job(params)
    checks.check("JobCreated decoded from the receipt", result.job_id is not None, f"jobId={result.job_id}")
    if result.job_id is None:
        raise RuntimeError("createJob produced no JobCreated event")

    job = clients["client_operator"].escrow.get_job(result.job_id)
    milestones = clients["client_operator"].escrow.get_milestones(result.job_id)
    checks.check("job status Open", job.status is JobStatus.OPEN, str(job.status))
    checks.check(
        "job total is $250.50 from USDC strings",
        job.total == JOB_TOTAL,
        f"{format_usdc(job.total)} USDC",
    )
    checks.check("a fresh job is an unaccepted offer", not job.accepted, f"acceptedAt={job.accepted_at}")
    checks.check(
        "two pending milestones",
        [m.amount for m in milestones] == [MILESTONE_ONE, MILESTONE_TWO]
        and all(m.status is MilestoneStatus.PENDING for m in milestones),
    )
    return result.job_id


def _accept_job(checks: Checks, clients: dict[str, NexusClient], job_id: int) -> None:
    """The provider binds itself to the offer; nothing else in the lifecycle works before this."""
    clients["provider_operator"].escrow.accept_job(job_id)
    job = clients["client_operator"].escrow.get_job(job_id)
    checks.check("provider accepted the job", job.accepted, f"acceptedAt={job.accepted_at}")


def _run_milestones(checks: Checks, clients: dict[str, NexusClient], job_id: int) -> None:
    provider_op = clients["provider_operator"]
    client_op = clients["client_operator"]
    for index in (0, 1):
        provider_op.escrow.submit_milestone(job_id, index, f"DELIVERABLE_{index}")
        submitted = provider_op.escrow.get_milestones(job_id)[index]
        checks.check(
            f"milestone {index} submitted", submitted.status is MilestoneStatus.SUBMITTED, str(submitted.status)
        )
        client_op.escrow.approve_milestone(job_id, index)
        approved = client_op.escrow.get_milestones(job_id)[index]
        checks.check(
            f"milestone {index} approved", approved.status is MilestoneStatus.APPROVED, str(approved.status)
        )


def _assert_settlement(
    checks: Checks, clients: dict[str, NexusClient], job_id: int, before: dict[str, int]
) -> None:
    client_op = clients["client_operator"]
    provider = clients["provider_principal"].address

    job = client_op.escrow.get_job(job_id)
    checks.check("job status Completed", job.status is JobStatus.COMPLETED, str(job.status))
    checks.check("job released equals total", job.released == JOB_TOTAL, format_usdc(job.released))

    balance = client_op.usdc.balance_of(provider)
    delta = balance - before["provider_balance"]
    checks.check("provider received $250.50 USDC", delta == JOB_TOTAL, f"delta={format_usdc(delta)}")

    stats = client_op.reputation.get_stats(provider)
    positives = stats.positives - before["provider_positives"]
    checks.check("provider gained 2 positive interactions", positives == 2, f"delta={positives}")
    checks.check(
        "provider tier and score readable",
        client_op.reputation.get_tier(provider).value in {"BRONZE", "SILVER", "GOLD", "PLATINUM"},
        f"score={client_op.reputation.get_score(provider)} tier={client_op.reputation.get_tier(provider).value}",
    )

    logs = client_op.audit_log.get_log_count(provider) - before["provider_logs"]
    checks.check("at least 4 audit log entries written", logs >= 4, f"new entries={logs}")
    entries = client_op.audit_log.get_agent_logs(provider, before["provider_logs"], 20)
    labels = sorted({entry.action_label for entry in entries})
    checks.check(
        "audit log action types decode to labels",
        any(entry.action_label.startswith("ESCROW_") for entry in entries),
        ", ".join(labels),
    )
    checks.check(
        "submission entries survive the gas buffer",
        "ESCROW_MILESTONE_SUBMITTED" in labels,
        "escrow logs inside try/catch need gas above eth_estimateGas",
    )

    job_ids = client_op.escrow.get_jobs_of(provider, 0, 50)
    checks.check("job indexed against the provider", job_id in job_ids, f"jobIds={job_ids}")


def main() -> int:
    checks = Checks()
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print(f"FAIL  cannot reach {RPC_URL}; start anvil --port 8546", file=sys.stderr)
        return 1
    if not Path(ADDRESSES_JSON).is_file():
        print(f"FAIL  {ADDRESSES_JSON} not found; run the DeployLocal forge script first", file=sys.stderr)
        return 1

    print(f"rpc={RPC_URL} chainId={w3.eth.chain_id} addresses={ADDRESSES_JSON}\n")
    clients = _clients(w3, ADDRESSES_JSON)
    provider = clients["provider_principal"].address
    before = {
        "provider_balance": clients["client_operator"].usdc.balance_of(provider),
        "provider_positives": clients["client_operator"].reputation.get_stats(provider).positives,
        "provider_logs": clients["client_operator"].audit_log.get_log_count(provider),
    }

    _authorize_operators(checks, clients)
    _approve_usdc(checks, clients)
    _register_identities(checks, clients)
    job_id = _create_job(checks, clients)
    _accept_job(checks, clients, job_id)
    _run_milestones(checks, clients, job_id)
    _assert_settlement(checks, clients, job_id, before)
    run_permit_phase(
        checks,
        w3,
        ADDRESSES_JSON,
        PERMIT_CLIENT_KEY,
        CLIENT_PRINCIPAL_KEY,
        provider,
        PROVIDER_OPERATOR_KEY,
    )
    run_settle_phase(checks, clients, provider)
    run_cancel_phase(checks, clients, provider)

    return checks.summary()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # surface the failure with a non-zero exit
        print(f"\nFAIL  e2e aborted: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
