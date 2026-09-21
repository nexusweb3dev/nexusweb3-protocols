"""`nexusweb3` command line interface.

Environment:
    NEXUS_RPC_URL        JSON-RPC endpoint (default http://127.0.0.1:8545)
    NEXUS_PRIVATE_KEY    signing key, required for writes
    NEXUS_ADDRESSES_JSON path to a deployments/v2-*.json file
    NEXUS_PRINCIPAL      agent principal the signer acts for (defaults to the signer itself)
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Callable

from web3 import Web3
from web3.exceptions import Web3Exception

from .client import NexusClient
from .errors import NexusError
from .serde import dumps, to_jsonable
from .types import CreateParams, ZERO_ADDRESS

Handler = Callable[[NexusClient, argparse.Namespace], Any]

DEFAULT_RPC_URL = "http://127.0.0.1:8545"


def _build_client(args: argparse.Namespace) -> NexusClient:
    addresses_json = args.addresses or os.environ.get("NEXUS_ADDRESSES_JSON")
    if not addresses_json:
        raise NexusError("set NEXUS_ADDRESSES_JSON (or --addresses) to a deployments/v2-*.json path")
    rpc_url = args.rpc_url or os.environ.get("NEXUS_RPC_URL", DEFAULT_RPC_URL)
    private_key = os.environ.get("NEXUS_PRIVATE_KEY")
    return NexusClient.from_rpc(rpc_url, addresses_json, private_key)


def _principal(client: NexusClient, args: argparse.Namespace) -> str:
    explicit = getattr(args, "agent", None) or os.environ.get("NEXUS_PRINCIPAL")
    if explicit:
        return Web3.to_checksum_address(explicit)
    if client.account is None:
        raise NexusError("no agent given: pass --agent, or set NEXUS_PRINCIPAL / NEXUS_PRIVATE_KEY")
    return client.address


def _amounts(raw: str, decimals: int) -> list[int]:
    from .contracts.erc20 import ERC20Client

    parts = [part.strip() for part in raw.split(",") if part.strip()]
    if not parts:
        raise NexusError("--amounts needs at least one value, e.g. 100,150")
    return [ERC20Client.to_units(part, decimals) for part in parts]


# ─── Handlers ───────────────────────────────────────────────────────────
def _identity_register(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = _principal(client, args)
    result = client.identity.register(agent, args.name, args.uri, args.type)
    return {"tx": result.hash, "agent": agent, "profile": client.identity.get_agent(agent)}


def _identity_get(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = _principal(client, args)
    return {
        "agent": agent,
        "registered": client.identity.is_registered(agent),
        "profile": client.identity.get_agent(agent),
        "erc8004Id": client.identity.erc8004_id_of(agent),
    }


def _reputation_get(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = _principal(client, args)
    return {
        "agent": agent,
        "score": client.reputation.get_score(agent),
        "tier": client.reputation.get_tier(agent),
        "stats": client.reputation.get_stats(agent),
    }


def _chain_now(client: NexusClient) -> int:
    """Latest block timestamp. The contract validates deadlines against chain time, not wall clock."""
    return int(client.w3.eth.get_block("latest")["timestamp"])


def _escrow_create(client: NexusClient, args: argparse.Namespace) -> Any:
    decimals = client.usdc.decimals()
    amounts = _amounts(args.amounts, decimals)
    deadline = args.deadline or _chain_now(client) + args.deadline_hours * 3600
    params = CreateParams(
        client=_principal(client, args),
        provider=Web3.to_checksum_address(args.provider),
        milestone_amounts=amounts,
        deadline=deadline,
        arbiter=Web3.to_checksum_address(args.arbiter) if args.arbiter else ZERO_ADDRESS,
        terms_hash=args.terms_hash or b"\x00" * 32,
    )
    result = client.escrow.create_job(params)
    return {"tx": result.hash, "jobId": result.job_id, "total": params.total, "deadline": deadline}


def _escrow_submit(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.submit_milestone(args.job_id, args.index, args.hash)
    return {"tx": result.hash, "jobId": args.job_id, "index": args.index}


def _escrow_approve(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.approve_milestone(args.job_id, args.index)
    job = client.escrow.get_job(args.job_id)
    return {"tx": result.hash, "jobId": args.job_id, "index": args.index, "status": job.status}


def _escrow_claim(client: NexusClient, args: argparse.Namespace) -> Any:
    result = client.escrow.claim_approval(args.job_id, args.index)
    job = client.escrow.get_job(args.job_id)
    return {"tx": result.hash, "jobId": args.job_id, "index": args.index, "status": job.status}


def _escrow_get(client: NexusClient, args: argparse.Namespace) -> Any:
    return {
        "jobId": args.job_id,
        "job": client.escrow.get_job(args.job_id),
        "expiry": client.escrow.expiry_of(args.job_id),
        "milestones": client.escrow.get_milestones(args.job_id),
    }


def _escrow_list(client: NexusClient, args: argparse.Namespace) -> Any:
    account = _principal(client, args)
    return {
        "account": account,
        "count": client.escrow.job_count_of(account),
        "jobIds": client.escrow.get_jobs_of(account, args.offset, args.limit),
    }


def _killswitch_status(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = _principal(client, args)
    return {
        "agent": agent,
        "active": client.kill_switch.is_active(agent),
        "config": client.kill_switch.get_config(agent),
        "remainingSpend": client.kill_switch.remaining_spend(agent),
        "guardian": client.kill_switch.guardian_of(agent),
    }


def _auditlog_list(client: NexusClient, args: argparse.Namespace) -> Any:
    agent = _principal(client, args)
    logs = client.audit_log.get_agent_logs(agent, args.offset, args.limit)
    return {
        "agent": agent,
        "count": client.audit_log.get_log_count(agent),
        "logs": [{**_log_dict(entry)} for entry in logs],
    }


def _log_dict(entry: Any) -> dict[str, Any]:
    data = to_jsonable(entry)
    data["actionLabel"] = entry.action_label
    return data


# ─── Parser ─────────────────────────────────────────────────────────────
def _add_agent_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--agent", help="agent principal (default: NEXUS_PRINCIPAL or the signer)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nexusweb3", description="NexusWeb3 v2 protocol CLI")
    parser.add_argument("--rpc-url", help="JSON-RPC endpoint (default: NEXUS_RPC_URL)")
    parser.add_argument("--addresses", help="deployments/v2-*.json (default: NEXUS_ADDRESSES_JSON)")
    groups = parser.add_subparsers(dest="group", required=True)

    identity = groups.add_parser("identity", help="agent identity").add_subparsers(dest="cmd", required=True)
    reg = identity.add_parser("register", help="register an agent identity")
    reg.add_argument("--name", required=True)
    reg.add_argument("--uri", default="", help="agent metadata URI")
    reg.add_argument("--type", type=int, default=0, help="agent type 0..10")
    _add_agent_arg(reg)
    reg.set_defaults(handler=_identity_register)
    get = identity.add_parser("get", help="read an agent profile")
    _add_agent_arg(get)
    get.set_defaults(handler=_identity_get)

    reputation = groups.add_parser("reputation", help="reputation").add_subparsers(dest="cmd", required=True)
    rep_get = reputation.add_parser("get", help="score, tier and stats")
    _add_agent_arg(rep_get)
    rep_get.set_defaults(handler=_reputation_get)

    escrow = groups.add_parser("escrow", help="milestone escrow").add_subparsers(dest="cmd", required=True)
    create = escrow.add_parser("create", help="create a job (client principal must have approved USDC)")
    create.add_argument("--provider", required=True)
    create.add_argument("--amounts", required=True, help="comma separated USDC amounts, e.g. 100,150")
    create.add_argument("--arbiter", help="optional arbiter address")
    create.add_argument("--deadline", type=int, help="absolute unix deadline")
    create.add_argument("--deadline-hours", type=int, default=24, help="deadline offset when --deadline is unset")
    create.add_argument("--terms-hash", help="0x hash or short label for the off-chain terms")
    _add_agent_arg(create)
    create.set_defaults(handler=_escrow_create)

    submit = escrow.add_parser("submit", help="provider submits a milestone")
    submit.add_argument("--job-id", type=int, required=True)
    submit.add_argument("--index", type=int, required=True)
    submit.add_argument("--hash", required=True, help="0x deliverable hash or short label")
    submit.set_defaults(handler=_escrow_submit)

    approve = escrow.add_parser("approve", help="client approves a milestone and pays the provider")
    approve.add_argument("--job-id", type=int, required=True)
    approve.add_argument("--index", type=int, required=True)
    approve.set_defaults(handler=_escrow_approve)

    claim = escrow.add_parser(
        "claim", help="provider claims a milestone the client left unreviewed past REVIEW_WINDOW"
    )
    claim.add_argument("--job-id", type=int, required=True)
    claim.add_argument("--index", type=int, required=True)
    claim.set_defaults(handler=_escrow_claim)

    job_get = escrow.add_parser("get", help="read a job and its milestones")
    job_get.add_argument("--job-id", type=int, required=True)
    job_get.set_defaults(handler=_escrow_get)

    job_list = escrow.add_parser("list", help="list job ids for an account")
    job_list.add_argument("--offset", type=int, default=0)
    job_list.add_argument("--limit", type=int, default=50)
    _add_agent_arg(job_list)
    job_list.set_defaults(handler=_escrow_list)

    killswitch = groups.add_parser("killswitch", help="kill switch").add_subparsers(dest="cmd", required=True)
    status = killswitch.add_parser("status", help="limits, session usage and guardian")
    _add_agent_arg(status)
    status.set_defaults(handler=_killswitch_status)

    auditlog = groups.add_parser("auditlog", help="audit log").add_subparsers(dest="cmd", required=True)
    log_list = auditlog.add_parser("list", help="paginated agent action log")
    log_list.add_argument("--offset", type=int, default=0)
    log_list.add_argument("--limit", type=int, default=50)
    _add_agent_arg(log_list)
    log_list.set_defaults(handler=_auditlog_list)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        client = _build_client(args)
        payload = args.handler(client, args)
    except NexusError as exc:
        print(dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    except (Web3Exception, ValueError, KeyError, FileNotFoundError) as exc:
        print(dumps({"error": f"{type(exc).__name__}: {exc}"}), file=sys.stderr)
        return 1
    print(dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
