"""Permit phase of the end-to-end run: fund a job with an EIP-2612 signature, no prior approve.

`script/v2/DeployLocal.s.sol` deploys `test/mocks/ERC20Mock.sol`, which has no `permit`, so this
phase deploys an EIP-2612 token plus a second `AgentEscrowV2` bound to it and wires the same
reputation, audit log and kill switch modules.
"""

from __future__ import annotations

import time
from dataclasses import replace
from typing import Any

from eth_account import Account
from web3 import Web3
from web3.logs import DISCARD

from nexusweb3 import (
    Addresses,
    CreateParams,
    JobStatus,
    MilestoneStatus,
    NexusClient,
    load_addresses,
    sign_permit,
)

from e2e_support import Checks, deploy, load_forge_artifact, load_local_artifact

MILESTONE = 75_000_000  # $75 USDC
MINT_AMOUNT = 1_000_000_000_000  # 1,000,000 USDC
REVIEW_WINDOW_SKIP = 8 * 24 * 3600  # one day past the 7-day review window


def _deploy_permit_stack(w3: Web3, owner: Any, addresses: Any, funded: str) -> tuple[str, str]:
    """Deploy the permit token and a second escrow, then wire the shared modules. Returns both."""
    token_abi, token_bytecode = load_local_artifact("ERC20PermitMock")
    token = deploy(w3, owner, token_abi, token_bytecode, "USD Coin", "USDC", 6)
    token_contract = w3.eth.contract(address=token, abi=token_abi)
    mint = token_contract.functions.mint(funded, MINT_AMOUNT)
    tx = mint.build_transaction(
        {
            "from": owner.address,
            "nonce": w3.eth.get_transaction_count(owner.address, "pending"),
            "chainId": w3.eth.chain_id,
            "gas": int(mint.estimate_gas({"from": owner.address}) * 5 // 4),
            "gasPrice": w3.eth.gas_price,
        }
    )
    signed = owner.sign_transaction(tx)
    w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))

    escrow_abi, escrow_bytecode = load_forge_artifact("AgentEscrowV2")
    escrow = deploy(w3, owner, escrow_abi, escrow_bytecode, addresses.access, token, owner.address)

    owner_client = NexusClient(w3, addresses, owner)
    owner_client.reputation.authorize_protocol(escrow)
    owner_client.audit_log.authorize_protocol(escrow)
    owner_client.kill_switch.authorize_protocol(escrow)
    wired = replace(addresses, escrow=escrow, payment_token=token)
    NexusClient(w3, wired, owner).escrow.set_modules(
        addresses.reputation, addresses.audit_log, addresses.kill_switch, addresses.fee_router
    )
    return token, escrow


def _advance_time(w3: Web3, seconds: int) -> None:
    """Move the anvil clock forward and mine a block so the new timestamp takes effect."""
    w3.provider.make_request("evm_increaseTime", [seconds])
    w3.provider.make_request("evm_mine", [])


def run_claim_phase(
    checks: Checks,
    w3: Web3,
    permit_addresses: Addresses,
    provider_operator_key: str,
    provider: str,
    job_id: int,
) -> None:
    """Provider submits, the client stays silent past REVIEW_WINDOW, provider claims the payout."""
    operator = NexusClient(w3, permit_addresses, Account.from_key(provider_operator_key))
    operator.escrow.submit_milestone(job_id, 0, "PERMIT_DELIVERABLE")
    deadline = operator.escrow.get_job(job_id).deadline
    expiry = operator.escrow.expiry_of(job_id)
    checks.check(
        "submission extends expiry past the deadline",
        expiry > deadline,
        f"expiry={expiry} deadline={deadline}",
    )

    balance_before = operator.usdc.balance_of(provider)
    _advance_time(w3, REVIEW_WINDOW_SKIP)
    result = operator.escrow.claim_approval(job_id, 0)
    claimed = operator.escrow.contract.events.MilestoneClaimed().process_receipt(
        result.receipt, errors=DISCARD
    )
    checks.check("MilestoneClaimed emitted", len(claimed) == 1, f"events={len(claimed)}")

    milestone = operator.escrow.get_milestones(job_id)[0]
    job = operator.escrow.get_job(job_id)
    paid = operator.usdc.balance_of(provider) - balance_before
    checks.check("claimed milestone is Approved", milestone.status is MilestoneStatus.APPROVED, str(milestone.status))
    checks.check("claimed job is Completed", job.status is JobStatus.COMPLETED, str(job.status))
    checks.check("provider paid by claimApproval", paid == MILESTONE, f"delta={paid}")


def run_permit_phase(
    checks: Checks,
    w3: Web3,
    addresses_json: str,
    permit_client_key: str,
    owner_key: str,
    provider: str,
    provider_operator_key: str,
) -> None:
    """Sign an EIP-2612 permit and create a job with it, without any prior `approve`."""
    addresses = load_addresses(addresses_json)
    owner = Account.from_key(owner_key)
    payer = Account.from_key(permit_client_key)

    token, escrow = _deploy_permit_stack(w3, owner, addresses, payer.address)
    permit_addresses = replace(addresses, escrow=escrow, payment_token=token)
    client = NexusClient(w3, permit_addresses, payer)

    checks.check(
        "permit payer holds tokens and has no allowance",
        client.usdc.balance_of(payer.address) == MINT_AMOUNT
        and client.usdc.allowance(payer.address, escrow) == 0,
    )

    permit_deadline = int(w3.eth.get_block("latest")["timestamp"]) + 3600
    v, r, s = sign_permit(payer, w3, token, escrow, MILESTONE, permit_deadline)
    checks.check(
        "permit signature has the expected shape",
        v in (27, 28) and len(r) == 32 and len(s) == 32,
        f"v={v}",
    )

    params = CreateParams(
        client=payer.address,
        provider=Web3.to_checksum_address(provider),
        milestone_amounts=[MILESTONE],
        deadline=int(w3.eth.get_block("latest")["timestamp"]) + 24 * 3600,
        terms_hash="PY_SDK_PERMIT_TERMS",
    )
    result = client.escrow.create_job_with_permit(params, permit_deadline, v, r, s)
    checks.check("createJobWithPermit returned a jobId", result.job_id is not None, f"jobId={result.job_id}")
    if result.job_id is None:
        return

    job = client.escrow.get_job(result.job_id)
    checks.check("permit job exists and is Open", job.status is JobStatus.OPEN, str(job.status))
    checks.check("permit job funded without a prior approve", job.total == MILESTONE, str(job.total))
    checks.check(
        "escrow holds the permit-funded balance",
        client.usdc.balance_of(escrow) == MILESTONE,
        str(client.usdc.balance_of(escrow)),
    )
    run_claim_phase(checks, w3, permit_addresses, provider_operator_key, provider, result.job_id)
