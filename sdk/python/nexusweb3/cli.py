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

from web3.exceptions import Web3Exception

from . import cli_handlers as handlers
from .client import NexusClient
from .errors import NexusError
from .serde import dumps

Handler = Callable[[NexusClient, argparse.Namespace], Any]

DEFAULT_RPC_URL = "http://127.0.0.1:8545"


def _build_client(args: argparse.Namespace) -> NexusClient:
    addresses_json = args.addresses or os.environ.get("NEXUS_ADDRESSES_JSON")
    if not addresses_json:
        raise NexusError("set NEXUS_ADDRESSES_JSON (or --addresses) to a deployments/v2-*.json path")
    rpc_url = args.rpc_url or os.environ.get("NEXUS_RPC_URL", DEFAULT_RPC_URL)
    private_key = os.environ.get("NEXUS_PRIVATE_KEY")
    return NexusClient.from_rpc(rpc_url, addresses_json, private_key)


# ─── Parser ─────────────────────────────────────────────────────────────
def _add_agent_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--agent", help="agent principal (default: NEXUS_PRINCIPAL or the signer)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nexusweb3",
        description="NexusWeb3 v2 protocol CLI. All amounts are USDC in dollars, never base units.",
    )
    parser.add_argument("--rpc-url", help="JSON-RPC endpoint (default: NEXUS_RPC_URL)")
    parser.add_argument("--addresses", help="deployments/v2-*.json (default: NEXUS_ADDRESSES_JSON)")
    groups = parser.add_subparsers(dest="group", required=True)

    identity = groups.add_parser("identity", help="agent identity").add_subparsers(dest="cmd", required=True)
    reg = identity.add_parser("register", help="register an agent identity")
    reg.add_argument("--name", required=True)
    reg.add_argument("--uri", default="", help="agent metadata URI")
    reg.add_argument("--type", type=int, default=0, help="agent type 0..10")
    _add_agent_arg(reg)
    reg.set_defaults(handler=handlers.identity_register)
    get = identity.add_parser("get", help="read an agent profile")
    _add_agent_arg(get)
    get.set_defaults(handler=handlers.identity_get)

    reputation = groups.add_parser("reputation", help="reputation").add_subparsers(dest="cmd", required=True)
    rep_get = reputation.add_parser("get", help="score, tier and stats")
    _add_agent_arg(rep_get)
    rep_get.set_defaults(handler=handlers.reputation_get)

    escrow = groups.add_parser("escrow", help="milestone escrow").add_subparsers(dest="cmd", required=True)
    create = escrow.add_parser("create", help="create a job (client principal must have approved USDC)")
    create.add_argument("--provider", required=True)
    create.add_argument(
        "--amounts", required=True, help="comma separated USDC amounts in dollars, e.g. 100,150.50"
    )
    create.add_argument("--arbiter", help="optional arbiter address")
    create.add_argument("--deadline", type=int, help="absolute unix deadline")
    create.add_argument("--deadline-hours", type=int, default=24, help="deadline offset when --deadline is unset")
    create.add_argument("--terms-hash", help="0x hash or short label for the off-chain terms")
    _add_agent_arg(create)
    create.set_defaults(handler=handlers.escrow_create)

    accept = escrow.add_parser("accept", help="provider accepts an offer, binding itself to the job")
    accept.add_argument("--job-id", type=int, required=True)
    accept.set_defaults(handler=handlers.escrow_accept)

    submit = escrow.add_parser("submit", help="provider submits a milestone")
    submit.add_argument("--job-id", type=int, required=True)
    submit.add_argument("--index", type=int, required=True)
    submit.add_argument("--hash", required=True, help="0x deliverable hash or short label")
    submit.set_defaults(handler=handlers.escrow_submit)

    approve = escrow.add_parser("approve", help="client approves a milestone and pays the provider")
    approve.add_argument("--job-id", type=int, required=True)
    approve.add_argument("--index", type=int, required=True)
    approve.set_defaults(handler=handlers.escrow_approve)

    claim = escrow.add_parser(
        "claim", help="provider claims a milestone the client left unreviewed past REVIEW_WINDOW"
    )
    claim.add_argument("--job-id", type=int, required=True)
    claim.add_argument("--index", type=int, required=True)
    claim.set_defaults(handler=handlers.escrow_claim)

    settle = escrow.add_parser(
        "settle", help="anyone: settle an expired job — submitted milestones pay, pending ones refund"
    )
    settle.add_argument("--job-id", type=int, required=True)
    settle.set_defaults(handler=handlers.escrow_settle)

    withdraw = escrow.add_parser("withdraw", help="sweep funds parked after a failed payout")
    withdraw.add_argument("--to", required=True, help="address that receives the tokens")
    _add_agent_arg(withdraw)
    withdraw.set_defaults(handler=handlers.escrow_withdraw)

    job_get = escrow.add_parser("get", help="read a job and its milestones")
    job_get.add_argument("--job-id", type=int, required=True)
    job_get.set_defaults(handler=handlers.escrow_get)

    job_list = escrow.add_parser("list", help="list job ids for an account")
    job_list.add_argument("--offset", type=int, default=0)
    job_list.add_argument("--limit", type=int, default=50)
    _add_agent_arg(job_list)
    job_list.set_defaults(handler=handlers.escrow_list)

    access = groups.add_parser("access", help="operator registry").add_subparsers(dest="cmd", required=True)
    renounce = access.add_parser(
        "renounce", help="this hot key gives up its own operator rights for an agent"
    )
    _add_agent_arg(renounce)
    renounce.set_defaults(handler=handlers.access_renounce)

    killswitch = groups.add_parser("killswitch", help="kill switch").add_subparsers(dest="cmd", required=True)
    status = killswitch.add_parser("status", help="limits, session usage and guardian")
    _add_agent_arg(status)
    status.set_defaults(handler=handlers.killswitch_status)

    auditlog = groups.add_parser("auditlog", help="audit log").add_subparsers(dest="cmd", required=True)
    log_list = auditlog.add_parser("list", help="paginated agent action log")
    log_list.add_argument("--offset", type=int, default=0)
    log_list.add_argument("--limit", type=int, default=50)
    _add_agent_arg(log_list)
    log_list.set_defaults(handler=handlers.auditlog_list)

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
