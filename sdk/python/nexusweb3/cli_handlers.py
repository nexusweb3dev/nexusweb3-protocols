"""Handlers behind the `nexusweb3` CLI subcommands.

Each one takes the built :class:`~nexusweb3.client.NexusClient` plus the parsed arguments and
returns a JSON-serializable payload; :mod:`nexusweb3.cli` owns the parser and the exit codes.
"""

from __future__ import annotations

import argparse
import os
from typing import Any

from web3 import Web3

from .amount import format_usdc, parse_usdc
from .client import NexusClient
from .errors import NexusError
from .serde import to_jsonable
from .types import CreateParams, ZERO_ADDRESS

#: `remainingSpend` returns uint256 max for an agent with no kill-switch limits.
UNLIMITED = (1 << 256) - 1

__all__ = [
    "access_renounce",
    "auditlog_list",
    "chain_now",
    "escrow_accept",
    "escrow_approve",
    "escrow_claim",
    "escrow_create",
    "escrow_get",
    "escrow_list",
    "escrow_settle",
    "escrow_submit",
    "escrow_withdraw",
    "identity_get",
    "identity_register",
    "identity_rename",
    "killswitch_status",
    "log_dict",
    "payout_list",
    "UNLIMITED",
    "parse_amounts",
    "principal",
    "reputation_get",
]


def principal(client: NexusClient, args: argparse.Namespace) -> str:
    explicit = getattr(args, "agent", None) or os.environ.get("NEXUS_PRINCIPAL")
    if explicit:
        return Web3.to_checksum_address(explicit)
    if client.account is None:
        raise NexusError("no agent given: pass --agent, or set NEXUS_PRINCIPAL / NEXUS_PRIVATE_KEY")
    return client.address


def parse_amounts(raw: str, decimals: int) -> list[int]:
    """Split a `--amounts` list of USDC figures ("100,150.50") into base units."""
    parts = [part.strip() for part in raw.split(",") if part.strip()]
    if not parts:
        raise NexusError("--amounts needs at least one value, e.g. 100,150.50")
    try:
        return [parse_usdc(part, f"--amounts[{i}]", decimals) for i, part in enumerate(parts)]
    except ValueError as exc:
        raise NexusError(str(exc)) from exc


def identity_register(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    result = client.identity.register(agent, args.name, args.uri, args.type)
    return {"tx": result.hash, "agent": agent, "profile": client.identity.get_agent(agent)}


def identity_rename(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    old_name = client.identity.get_agent(agent).name
    result = client.identity.rename(agent, args.name)
    return {
        "tx": result.hash,
        "agent": agent,
        "oldName": old_name,
        "newName": args.name,
        "profile": client.identity.get_agent(agent),
    }


def identity_get(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    return {
        "agent": agent,
        "registered": client.identity.is_registered(agent),
        "profile": client.identity.get_agent(agent),
        "erc8004Id": client.identity.erc8004_id_of(agent),
    }


def reputation_get(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    stats = client.reputation.get_stats(agent)
    return {
        "agent": agent,
        "score": client.reputation.get_score(agent),
        "tier": client.reputation.get_tier(agent),
        "stats": {**to_jsonable(stats), "volume_usdc": format_usdc(stats.volume_usdc)},
    }


def payout_list(result: Any) -> list[dict[str, Any]]:
    """Render `TxResult.payouts` for CLI output, amounts in USDC.

    `delivered: false` is not a failed call — the transfer bounced and the amount is now parked as
    claimable for that account, recoverable with `escrow withdraw`.
    """
    return [
        {
            "account": payout.account,
            "amountUsdc": format_usdc(payout.amount),
            "delivered": payout.delivered,
        }
        for payout in result.payouts
    ]


def chain_now(client: NexusClient) -> int:
    """Latest block timestamp. The contract validates deadlines against chain time, not wall clock."""
    return int(client.w3.eth.get_block("latest")["timestamp"])


def escrow_create(client: NexusClient, args: argparse.Namespace) -> Any:
    decimals = client.usdc.decimals()
    milestone_amounts = parse_amounts(args.amounts, decimals)
    deadline = args.deadline or chain_now(client) + args.deadline_hours * 3600
    params = CreateParams(
        client=principal(client, args),
        provider=Web3.to_checksum_address(args.provider),
        milestone_amounts=milestone_amounts,
        deadline=deadline,
        arbiter=Web3.to_checksum_address(args.arbiter) if args.arbiter else ZERO_ADDRESS,
        terms_hash=args.terms_hash or b"\x00" * 32,
    )
    result = client.escrow.create_job(params)
    return {
        "tx": result.hash,
        "jobId": result.job_id,
        "totalUsdc": format_usdc(params.total),
        "deadline": deadline,
    }


def escrow_accept(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.accept_job(args.job_id)
    job = client.escrow.get_job(args.job_id)
    return {"tx": result.hash, "jobId": args.job_id, "acceptedAt": job.accepted_at, "status": job.status}


def escrow_settle(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.settle_expired(args.job_id)
    job = client.escrow.get_job(args.job_id)
    return {
        "tx": result.hash,
        "jobId": args.job_id,
        "toProviderUsdc": None if result.to_provider is None else format_usdc(result.to_provider),
        "toClientUsdc": None if result.to_client is None else format_usdc(result.to_client),
        "payouts": payout_list(result),
        "status": job.status,
    }


def escrow_withdraw(client: NexusClient, args: argparse.Namespace) -> Any:
    account = principal(client, args)
    result = client.escrow.withdraw_claimable(account, Web3.to_checksum_address(args.to))
    withdrawn = None if result.withdrawn is None else format_usdc(result.withdrawn)
    return {"tx": result.hash, "account": account, "to": args.to, "withdrawnUsdc": withdrawn}


def escrow_submit(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.submit_milestone(args.job_id, args.index, args.hash)
    return {"tx": result.hash, "jobId": args.job_id, "index": args.index}


def escrow_approve(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.approve_milestone(args.job_id, args.index)
    job = client.escrow.get_job(args.job_id)
    return {
        "tx": result.hash,
        "jobId": args.job_id,
        "index": args.index,
        "payouts": payout_list(result),
        "status": job.status,
    }


def escrow_claim(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.claim_approval(args.job_id, args.index)
    job = client.escrow.get_job(args.job_id)
    return {
        "tx": result.hash,
        "jobId": args.job_id,
        "index": args.index,
        "payouts": payout_list(result),
        "status": job.status,
    }


def escrow_get(client: NexusClient, args: argparse.Namespace) -> Any:
    job = client.escrow.get_job(args.job_id)
    milestones = client.escrow.get_milestones(args.job_id)
    return {
        "jobId": args.job_id,
        "job": {
            **to_jsonable(job),
            "total_usdc": format_usdc(job.total),
            "released_usdc": format_usdc(job.released),
            "refunded_usdc": format_usdc(job.refunded),
        },
        "expiry": client.escrow.expiry_of(args.job_id),
        "milestones": [
            {**to_jsonable(m), "amount_usdc": format_usdc(m.amount)} for m in milestones
        ],
    }


def escrow_list(client: NexusClient, args: argparse.Namespace) -> Any:
    account = principal(client, args)
    return {
        "account": account,
        "count": client.escrow.job_count_of(account),
        "jobIds": client.escrow.get_jobs_of(account, args.offset, args.limit),
    }


def access_renounce(client: NexusClient, args: argparse.Namespace) -> Any:
    """Drop the signing key's own authorization; the principal need not be online."""
    agent = principal(client, args)
    result = client.access.renounce_operator(agent)
    return {"tx": result.hash, "agent": agent, "operator": client.address}


def killswitch_status(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    config = client.kill_switch.get_config(agent)
    remaining = client.kill_switch.remaining_spend(agent)
    return {
        "agent": agent,
        "active": client.kill_switch.is_active(agent),
        "config": {
            **to_jsonable(config),
            "spending_limit_usdc": format_usdc(config.spending_limit),
            "spent_usdc": format_usdc(config.spent),
        },
        "remainingSpendUsdc": "unlimited" if remaining == UNLIMITED else format_usdc(remaining),
        "guardian": client.kill_switch.guardian_of(agent),
    }


def auditlog_list(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = principal(client, args)
    logs = client.audit_log.get_agent_logs(agent, args.offset, args.limit)
    return {
        "agent": agent,
        "count": client.audit_log.get_log_count(agent),
        "logs": [{**log_dict(entry)} for entry in logs],
    }


def log_dict(entry: Any) -> dict[str, Any]:
    data = to_jsonable(entry)
    data["actionLabel"] = entry.action_label
    return data
