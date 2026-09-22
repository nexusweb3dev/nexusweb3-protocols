"""Helpers shared by the end-to-end script: result tracking, accounts, raw deployment."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3

REPO_ROOT = Path(__file__).resolve().parents[3]
FORGE_OUT = REPO_ROOT / "out"
LOCAL_ARTIFACTS = Path(__file__).resolve().parent / "artifacts"


@dataclass
class Result:
    name: str
    passed: bool
    detail: str = ""


class Checks:
    """Collects assertions and prints one PASS/FAIL line each."""

    def __init__(self) -> None:
        self.results: list[Result] = []

    def check(self, name: str, passed: bool, detail: str = "") -> bool:
        self.results.append(Result(name, bool(passed), detail))
        marker = "PASS" if passed else "FAIL"
        suffix = f"  ({detail})" if detail else ""
        stream = sys.stdout if passed else sys.stderr
        print(f"{marker}  {name}{suffix}", file=stream)
        return bool(passed)

    def summary(self) -> int:
        failed = [r for r in self.results if not r.passed]
        total = len(self.results)
        print(f"\n{total - len(failed)}/{total} checks passed")
        if failed:
            for result in failed:
                print(f"  FAILED: {result.name} {result.detail}", file=sys.stderr)
            print("E2E RESULT: FAIL", file=sys.stderr)
            return 1
        print("E2E RESULT: PASS")
        return 0


def anvil_account(private_key: str) -> LocalAccount:
    return Account.from_key(private_key)


def advance_time(w3: Web3, seconds: int) -> None:
    """Move the anvil clock forward and mine a block so the new timestamp takes effect."""
    w3.provider.make_request("evm_increaseTime", [seconds])
    w3.provider.make_request("evm_mine", [])


def load_forge_artifact(contract: str) -> tuple[list[dict[str, Any]], str]:
    """Return `(abi, bytecode)` for a contract built by the repo's `forge build`."""
    path = FORGE_OUT / f"{contract}.sol" / f"{contract}.json"
    if not path.is_file():
        raise FileNotFoundError(f"{path} missing; run `forge build` in the repo root")
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["abi"], data["bytecode"]["object"]


def load_local_artifact(contract: str) -> tuple[list[dict[str, Any]], str]:
    """Return `(abi, bytecode)` for an SDK-only helper contract in `scripts/artifacts`."""
    path = LOCAL_ARTIFACTS / f"{contract}.json"
    if not path.is_file():
        raise FileNotFoundError(
            f"{path} missing; rebuild with "
            "`forge build --contracts sdk/python/contracts --out sdk/python/.forge-out`"
        )
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["abi"], data["bytecode"]


def deploy(
    w3: Web3, account: LocalAccount, abi: list[dict[str, Any]], bytecode: str, *args: Any
) -> str:
    """Deploy a contract from raw artifact data and return its address."""
    factory = w3.eth.contract(abi=abi, bytecode=bytecode)
    constructor = factory.constructor(*args)
    tx = constructor.build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address, "pending"),
            "chainId": w3.eth.chain_id,
            "gas": int(constructor.estimate_gas({"from": account.address}) * 5 // 4),
            "gasPrice": w3.eth.gas_price,
        }
    )
    signed = account.sign_transaction(tx)
    receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))
    if int(receipt["status"]) != 1 or not receipt["contractAddress"]:
        raise RuntimeError("contract deployment reverted")
    return Web3.to_checksum_address(receipt["contractAddress"])
