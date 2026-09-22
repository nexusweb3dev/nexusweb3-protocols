"""Unit tests for the parts of the SDK that need no chain."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from eth_account import Account
from eth_account.messages import encode_typed_data

from nexusweb3 import (
    BASE_ERC8004_IDENTITY_REGISTRY,
    Addresses,
    CreateParams,
    Job,
    JobStatus,
    Milestone,
    MilestoneStatus,
    Payout,
    Tier,
    ZERO_ADDRESS,
    ZERO_BYTES32,
    coerce_bytes32,
    from_bytes32,
    load_addresses,
    to_bytes32,
)
from nexusweb3.abi import load_abi
from nexusweb3.contracts.erc20 import ERC20Client
from nexusweb3.contracts.reputation import _TIERS
from nexusweb3.permit import BASE_USDC_PERMIT_VERSION, build_permit_typed_data
from nexusweb3.revert import build_error_index, decode_revert
from nexusweb3.serde import to_jsonable
from nexusweb3.types import ActionLog, AgentConfig, AgentProfile, Stats

DEPLOYMENT = {
    "AgentAccess": "0x0165878a594ca255338adfa4d48449f69242eb8f",
    "AgentAuditLogV2": "0x610178da211fef7d417bc0e6fed39f05609ad788",
    "AgentEscrowV2": "0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0",
    "AgentIdentityV2": "0xa513e6e4b8f2a923d98304ec87f64353c4d5c853",
    "AgentKillSwitchV2": "0x8a791620dd6260079bf849dc5567adc3f2fdc318",
    "AgentReputationV2": "0x2279b7a0a67db372996a5fab50d91eaa73d2ebe6",
    "FeeRouter": "0xb7f8bc63bbcad18155201308c8f3540b07f84f5e",
    "chainId": 31337,
    "owner": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "paymentToken": "0x5fbdb2315678afecb367f032d93f642f64180aa3",
    "treasury": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
}


# ─── addresses ──────────────────────────────────────────────────────────
def test_load_addresses_from_mapping_checksums_every_field() -> None:
    addresses = load_addresses(DEPLOYMENT)
    assert addresses.access == "0x0165878A594ca255338adfa4d48449f69242Eb8F"
    assert addresses.escrow == "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0"
    assert addresses.payment_token == "0x5FbDB2315678afecb367f032d93F642f64180aa3"
    assert addresses.kill_switch == "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
    assert addresses.erc8004_registry == ZERO_ADDRESS


def test_load_addresses_from_file(tmp_path: Path) -> None:
    path = tmp_path / "v2-31337.json"
    path.write_text(json.dumps(DEPLOYMENT), encoding="utf-8")
    assert load_addresses(path) == load_addresses(DEPLOYMENT)
    assert load_addresses(str(path)).identity == "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853"


def test_load_addresses_accepts_field_names_and_optional_registry() -> None:
    data = dict(load_addresses(DEPLOYMENT).to_dict())
    data["erc8004Registry"] = BASE_ERC8004_IDENTITY_REGISTRY
    assert load_addresses(data).erc8004_registry == BASE_ERC8004_IDENTITY_REGISTRY


def test_load_addresses_reports_missing_key() -> None:
    incomplete = {k: v for k, v in DEPLOYMENT.items() if k != "FeeRouter"}
    with pytest.raises(KeyError, match="FeeRouter"):
        load_addresses(incomplete)


def test_load_addresses_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_addresses(tmp_path / "nope.json")


def test_addresses_rejects_non_string() -> None:
    fields = load_addresses(DEPLOYMENT).to_dict()
    fields["escrow"] = 42
    with pytest.raises(TypeError):
        Addresses(**fields)


def test_base_erc8004_registry_constant() -> None:
    assert BASE_ERC8004_IDENTITY_REGISTRY == "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"


# ─── bytes32 ────────────────────────────────────────────────────────────
@pytest.mark.parametrize("label", ["JOB_CREATED", "x", "MILESTONE_APPROVED", "a" * 32])
def test_bytes32_round_trip(label: str) -> None:
    packed = to_bytes32(label)
    assert len(packed) == 32
    assert from_bytes32(packed) == label


def test_to_bytes32_rejects_oversized_label() -> None:
    with pytest.raises(ValueError, match="33 bytes"):
        to_bytes32("a" * 33)


def test_coerce_bytes32_accepts_label_hex_bytes_and_none() -> None:
    assert coerce_bytes32("SUBMITTED") == to_bytes32("SUBMITTED")
    digest = "0x" + "ab" * 32
    assert coerce_bytes32(digest) == bytes.fromhex("ab" * 32)
    assert coerce_bytes32(b"\x01" * 32) == b"\x01" * 32
    assert coerce_bytes32(None) == ZERO_BYTES32
    assert coerce_bytes32(b"\x07") == b"\x00" * 31 + b"\x07"


def test_coerce_bytes32_rejects_wrong_length_hex() -> None:
    with pytest.raises(ValueError, match="32 bytes"):
        coerce_bytes32("0xdeadbeef")


# ─── enums and structs ──────────────────────────────────────────────────
def test_tier_order_matches_contract_enum() -> None:
    assert [t.value for t in _TIERS] == ["BRONZE", "SILVER", "GOLD", "PLATINUM"]
    assert list(Tier) == list(_TIERS)


def _job_tuple(status_index: int, *, accepted_at: int = 0, ever_submitted: bool = False) -> list[object]:
    """Solidity `Job` field order: the two timestamps and `everSubmitted` came with the audit."""
    return [
        ZERO_ADDRESS,  # client
        ZERO_ADDRESS,  # provider
        ZERO_ADDRESS,  # arbiter
        250_000_000,  # total
        0,  # released
        0,  # refunded
        1,  # deadline
        2,  # createdAt
        accepted_at,  # acceptedAt
        0,  # disputedAt
        2,  # milestoneCount
        0,  # approvedCount
        ever_submitted,  # everSubmitted
        status_index,
        ZERO_BYTES32,  # termsHash
    ]


def test_job_status_decoded_by_index() -> None:
    order = ["Open", "Completed", "Cancelled", "Disputed", "Resolved", "Expired"]
    assert [s.value for s in JobStatus] == order
    for index, name in enumerate(order):
        job = Job.from_tuple(_job_tuple(index))
        assert job.status == JobStatus(name)
        assert job.total == 250_000_000


def test_job_exposes_the_acceptance_fields() -> None:
    offer = Job.from_tuple(_job_tuple(0))
    assert (offer.accepted_at, offer.accepted, offer.ever_submitted) == (0, False, False)
    live = Job.from_tuple(_job_tuple(0, accepted_at=1_700_000_000, ever_submitted=True))
    assert (live.accepted_at, live.accepted, live.ever_submitted) == (1_700_000_000, True, True)
    assert live.disputed_at == 0


def test_milestone_status_decoded_by_index() -> None:
    assert [s.value for s in MilestoneStatus] == ["Pending", "Submitted", "Approved"]
    milestone = Milestone.from_tuple([100_000_000, ZERO_BYTES32, 1_700_000_000, 2, 1])
    assert milestone.status is MilestoneStatus.SUBMITTED
    assert milestone.rejections == 2


def test_job_from_tuple_rejects_unknown_status_index() -> None:
    with pytest.raises(ValueError, match="out of range"):
        Job.from_tuple(_job_tuple(9))


def test_struct_dataclasses_map_every_field() -> None:
    profile = AgentProfile.from_tuple(["nexus", "ipfs://x", 3, 10, 20, True])
    assert (profile.name, profile.agent_type, profile.active) == ("nexus", 3, True)
    stats = Stats.from_tuple([2, 0, 250_000_000, 11, 22])
    assert (stats.positives, stats.volume_usdc) == (2, 250_000_000)
    config = AgentConfig.from_tuple([5, 1, 10, 2, 3600, 100, True, False, False])
    assert (config.spending_limit, config.registered, config.killed) == (5, True, False)
    entry = ActionLog.from_tuple(
        [ZERO_ADDRESS, ZERO_ADDRESS, to_bytes32("JOB_CREATED"), ZERO_BYTES32, 7, 1, 2]
    )
    assert entry.action_label == "JOB_CREATED"


def test_create_params_tuple_ordering_and_total() -> None:
    params = CreateParams(
        client="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        provider="0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        milestone_amounts=[100_000_000, 150_000_000],
        deadline=1_800_000_000,
        terms_hash="TERMS_V1",
    )
    encoded = params.to_tuple()
    assert encoded[0] == params.client
    assert encoded[2] == ZERO_ADDRESS
    assert encoded[3] == [100_000_000, 150_000_000]
    assert encoded[5] == to_bytes32("TERMS_V1")
    assert params.total == 250_000_000


def test_create_params_requires_a_milestone() -> None:
    params = CreateParams(client=ZERO_ADDRESS, provider=ZERO_ADDRESS, milestone_amounts=[], deadline=1)
    with pytest.raises(ValueError, match="at least one milestone"):
        params.to_tuple()


# ─── permit typed data ──────────────────────────────────────────────────
BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
BASE_SEPOLIA_USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
TOKEN = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
SPENDER = "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0"
KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"


def _typed_data(version: str = "1") -> dict[str, object]:
    return build_permit_typed_data(
        token=TOKEN,
        token_name="USD Coin",
        chain_id=8453,
        owner=Account.from_key(KEY).address,
        spender=SPENDER,
        value=250_000_000,
        nonce=0,
        deadline=1_800_000_000,
        version=version,
    )


def test_permit_typed_data_structure() -> None:
    data = _typed_data()
    assert data["primaryType"] == "Permit"
    assert [f["name"] for f in data["types"]["Permit"]] == [
        "owner",
        "spender",
        "value",
        "nonce",
        "deadline",
    ]
    assert [f["name"] for f in data["types"]["EIP712Domain"]] == [
        "name",
        "version",
        "chainId",
        "verifyingContract",
    ]
    assert data["domain"] == {
        "name": "USD Coin",
        "version": "1",
        "chainId": 8453,
        "verifyingContract": TOKEN,
    }
    assert data["message"]["spender"] == SPENDER
    assert data["message"]["value"] == 250_000_000


def test_permit_version_override_for_base_usdc() -> None:
    assert BASE_USDC_PERMIT_VERSION == "2"
    assert _typed_data(BASE_USDC_PERMIT_VERSION)["domain"]["version"] == "2"


def test_permit_signature_recovers_to_the_owner() -> None:
    account = Account.from_key(KEY)
    data = _typed_data()
    signed = account.sign_typed_data(full_message=data)
    recovered = Account.recover_message(encode_typed_data(full_message=data), signature=signed.signature)
    assert recovered == account.address
    assert int(signed.v) in (27, 28)
    assert len(int(signed.r).to_bytes(32, "big")) == 32



def test_unit_conversion_round_trip() -> None:
    assert ERC20Client.to_units("100.5") == 100_500_000
    assert ERC20Client.from_units(250_000_000) == "250"
    with pytest.raises(ValueError, match="decimal places"):
        ERC20Client.to_units("1.0000001")



def test_to_jsonable_handles_bytes_enums_and_dataclasses() -> None:
    milestone = Milestone.from_tuple([1, to_bytes32("HASH"), 2, 0, 2])
    payload = to_jsonable(milestone)
    assert payload["status"] == "Approved"
    assert payload["deliverable_hash"].startswith("0x48415348")


# ─── custom error decoding ──────────────────────────────────────────────
class _FakeRevert(Exception):
    def __init__(self, data: str) -> None:
        super().__init__(data)
        self.data = data


def test_decode_revert_names_custom_errors_with_arguments() -> None:
    index = build_error_index(load_abi("AgentEscrowV2"))
    job_not_found = "0x50c83b95" + "63".rjust(64, "0")
    assert decode_revert(index, _FakeRevert(job_not_found)) == "JobNotFound(jobId=99)"


def test_decode_revert_handles_argument_free_errors() -> None:
    index = build_error_index(load_abi("AgentEscrowV2"))
    selector = next(sel for sel, (name, types, _) in index.items() if name == "InvalidParty" and not types)
    assert decode_revert(index, _FakeRevert("0x" + selector.hex())) == "InvalidParty()"


def test_decode_revert_returns_none_for_unknown_payloads() -> None:
    index = build_error_index(load_abi("AgentEscrowV2"))
    assert decode_revert(index, _FakeRevert("0xdeadbeef")) is None
    assert decode_revert(index, Exception("boom")) is None


# ─── payouts ────────────────────────────────────────────────────────────
def test_payout_decodes_a_settled_event_argument_bag() -> None:
    delivered = Payout.from_args(
        {"jobId": 7, "account": "0x0000000000000000000000000000000000000a11", "amount": 250_500_000, "delivered": True}
    )
    assert delivered.account == "0x0000000000000000000000000000000000000a11"
    assert delivered.amount == 250_500_000
    assert delivered.delivered is True


def test_payout_marks_a_bounced_transfer_as_undelivered() -> None:
    """A failed transfer is parked as claimable; the transaction still succeeds."""
    parked = Payout.from_args(
        {"jobId": 7, "account": "0x0000000000000000000000000000000000000a22", "amount": 100, "delivered": False}
    )
    assert parked.delivered is False
    assert to_jsonable(parked) == {
        "account": "0x0000000000000000000000000000000000000a22",
        "amount": 100,
        "delivered": False,
    }


def test_tx_result_defaults_to_no_payouts() -> None:
    from nexusweb3.tx import TxResult

    assert TxResult(hash="0x1", receipt={}).payouts == ()


def test_cli_renders_payouts_in_usdc() -> None:
    from nexusweb3.cli_handlers import payout_list
    from nexusweb3.tx import TxResult

    result = TxResult(
        hash="0x1",
        receipt={},
        payouts=(
            Payout("0x0000000000000000000000000000000000000a11", 250_500_000, True),
            Payout("0x0000000000000000000000000000000000000a22", 1_000_000, False),
        ),
    )
    assert payout_list(result) == [
        {"account": "0x0000000000000000000000000000000000000a11", "amountUsdc": "250.5", "delivered": True},
        {"account": "0x0000000000000000000000000000000000000a22", "amountUsdc": "1", "delivered": False},
    ]


def test_cli_parses_identity_rename() -> None:
    from nexusweb3.cli import build_parser

    args = build_parser().parse_args(["identity", "rename", "--name", "new-handle"])
    assert args.handler.__name__ == "identity_rename"
    assert args.name == "new-handle"
