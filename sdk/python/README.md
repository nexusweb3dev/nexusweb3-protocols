# nexusweb3 (Python SDK)

Typed Python client for the NexusWeb3 **v2** agent protocol: operator-gated identity, reputation,
kill switch, audit log, fee router and milestone escrow. Built on `web3.py` v7/v8.

## Install

```bash
cd sdk/python
python3 -m venv .venv && . .venv/bin/activate
pip install -e '.[dev]'
python scripts/sync_abis.py      # copies the 7 ABIs out of ../../out (run `forge build` first)
```

`scripts/sync_abis.py` writes `nexusweb3/abis/<Contract>.json`; re-run it after any contract change.

## Amounts are USDC, not base units

Every amount you pass to this SDK and its CLI is a **USDC figure in dollars**: `"100.50"` is one
hundred dollars fifty. There is no 1e6 conversion to do by hand.

```python
from nexusweb3 import format_usdc, parse_usdc

client.usdc.approve(addresses.escrow, "1000")        # 1000 USDC
client.kill_switch.register("500", 20, 86_400)       # 500 USDC per session
parse_usdc("100.50")                                 # 100500000, when you need base units
```

Reads return `int` base units, because that is what the chain stores — `format_usdc` turns one back
into a dollar figure. An `int` passed *in* is therefore read as base units too: the type, not the
digits, decides, so `100` is 0.0001 USDC while `"100"` is one hundred dollars. Anything finer than
six decimal places is rejected rather than silently truncated.

## Quickstart

The ten-minute integration from `docs/MIGRATION.md`, in Python:

```python
from eth_account import Account
from web3 import Web3
from nexusweb3 import CreateParams, NexusClient, load_addresses

w3 = Web3(Web3.HTTPProvider("https://mainnet.base.org"))
addresses = load_addresses("deployments/v2-8453.json")

principal = NexusClient(w3, addresses, Account.from_key(COLD_KEY))
principal.access.authorize_operator(HOT_KEY_ADDRESS)          # 1. authorize the hot key
principal.usdc.approve(addresses.escrow, "250")               # 2. or use create_job_with_permit
principal.kill_switch.register("1000", 50, 86_400)            # 3. optional spending guard

agent = NexusClient(w3, addresses, Account.from_key(HOT_KEY))  # the hot key holds nothing
agent.identity.register(principal.address, "my-agent", "ipfs://profile.json", 1)
job = agent.escrow.create_job(CreateParams(
    client=principal.address, provider=PROVIDER, milestone_amounts=["100", "150.50"],
    deadline=int(time.time()) + 7 * 86_400, terms_hash="TERMS_V1",
))
provider_agent.escrow.accept_job(job.job_id)                   # provider side: binds it to the offer
agent.escrow.approve_milestone(job.job_id, 0)                  # provider paid, reputation written
```

`create_job` posts an **offer**: the funds are locked but the provider is not bound to anything
until `accept_job`, signed by the provider or one of its operators, lands before the job deadline.
Until then `submit_milestone`, `approve_milestone` and `dispute` revert with `NotAccepted`, and the
client can walk away with `cancel_job` for a full refund. `job.accepted` reads the flag.

Sub-clients: `access`, `identity`, `reputation`, `kill_switch`, `audit_log`, `escrow`, `fee_router`,
`usdc`. Reads need no account; writes sign, send and wait for the receipt, returning a `TxResult`
with `hash`, `receipt` and `job_id` / `log_id` decoded from `JobCreated` / `ActionLogged`.

Structs come back as dataclasses (`AgentProfile`, `Stats`, `AgentConfig`, `Job`, `Milestone`,
`ActionLog`) and enums as readable strings (`JobStatus.OPEN.value == "Open"`, `Tier.GOLD`).
`bytes32` action types round-trip through `to_bytes32` / `from_bytes32`. `Job` carries
`accepted_at`, `disputed_at` and `ever_submitted`; `Milestone` carries `rejections`.

### When the counterparty goes quiet

`escrow.settle_expired(job_id)` is permissionless and replaces the old refund-only path. It splits
by state, not by who shows up: every **Submitted** milestone vests to the provider and every
**Pending** one refunds the client. Open jobs qualify past `expiry_of`, and a `Disputed` job whose
arbiter never ruled qualifies `dispute_grace()` (30 days) after `job.disputed_at`.

```python
result = client.escrow.settle_expired(job_id)          # anyone may call this
print(result.to_provider, result.to_client)            # decoded from JobExpired

swept = client.escrow.withdraw_claimable(PRINCIPAL, TREASURY)   # (account, to)
print(swept.withdrawn)                                 # decoded from ClaimableWithdrawn
```

`withdraw_claimable` takes the account whose parked balance is being swept and the address that
receives the tokens; it is signed by that account or one of its operators, and `to` must not be the
zero address. A milestone tolerates `max_rejections()` (3) rejections, each only inside the review
window (`ReviewWindowClosed` afterwards), and one client/provider pair generates at most
`max_reputation_per_pair()` (10) reputation entries.

### Governance and module notes

Every v2 contract except `AgentAccess` is `Ownable2Step`, so each sub-client exposes `owner()`,
`pending_owner()`, `transfer_ownership(new_owner)` and `accept_ownership()`. A transfer only
proposes; nothing moves until the proposed address calls `accept_ownership` itself.

`nexusweb3 access renounce` and `access.renounce_operator(agent)` are signed by the operator itself, so a hot key that may have
leaked can cut itself off without waiting for the principal. `identity.register` accepts only
lowercase `a-z`, digits, `-`, `_` and `.` in a name; anything else reverts with `InvalidName`.

`kill_switch.reset_session` is **principal-only** — it restores spending headroom, so neither an
operator nor the restrict-only guardian may call it (`NotPrincipal` otherwise), and
`remaining_spend` never reverts. `identity.link_erc8004` rejects a zero `agent_id`
(`InvalidERC8004Id`), and links written before the owner last repointed the contract at another
registry read back as unlinked — compare `identity.registry_epoch()` if you cache them off-chain.
`fee_router.route` emits `ReferralCallFailed` and keeps going when a referral sink reverts.

### Permit (EIP-2612)

```python
from nexusweb3 import sign_permit

v, r, s = sign_permit(account, w3, addresses.payment_token, addresses.escrow, "250", deadline)
client.escrow.create_job_with_permit(params, deadline, v, r, s)
```

`sign_permit` works out the EIP-712 domain version itself, through `resolve_permit_version`: the
token's ERC-5267 `eip712Domain()` when it has one, then `KNOWN_PERMIT_VERSIONS` for deployments
that do not (Base and Base Sepolia USDC sign with `"2"` and expose no descriptor), then `"1"`,
which every other EIP-2612 token uses. Pass `version=` to override. Signing under the wrong version
yields a signature the token silently rejects, which is why detection beats a blanket default.

## CLI

```bash
export NEXUS_RPC_URL=http://127.0.0.1:8546
export NEXUS_ADDRESSES_JSON=../../deployments/v2-local-py.json
export NEXUS_PRIVATE_KEY=0x...        # the operator hot key
export NEXUS_PRINCIPAL=0x...          # the agent principal it acts for

nexusweb3 access renounce --agent 0xPRINCIPAL   # this hot key drops its own rights
nexusweb3 identity register --name my-agent --uri ipfs://profile.json --type 1
nexusweb3 identity get --agent 0xPRINCIPAL
nexusweb3 reputation get --agent 0xPRINCIPAL
nexusweb3 escrow create --provider 0xPROVIDER --amounts 100,150 --deadline-hours 168
nexusweb3 escrow accept --job-id 0               # provider, before anything else works
nexusweb3 escrow submit --job-id 0 --index 0 --hash DELIVERABLE_0
nexusweb3 escrow approve --job-id 0 --index 0
nexusweb3 escrow claim --job-id 0 --index 0      # provider, after the 7-day review window
nexusweb3 escrow settle --job-id 0               # anyone, once the job expired
nexusweb3 escrow withdraw --to 0xTREASURY        # sweep funds parked after a failed payout
nexusweb3 escrow get --job-id 0
nexusweb3 escrow list --agent 0xPRINCIPAL
nexusweb3 killswitch status --agent 0xPRINCIPAL
nexusweb3 auditlog list --agent 0xPRINCIPAL --limit 20
```

Every command prints JSON and exits non-zero on error. Amounts in and out are USDC in dollars
(`--amounts 100,150.50` is a $250.50 job), never base units.

## Tests

```bash
pytest -q                 # 59 unit tests, no chain needed
```

## End-to-end

```bash
cd ../..                                  # repo root
anvil --port 8546 --silent &
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  DEPLOY_JSON_PATH=deployments/v2-local-py.json \
  forge script script/v2/DeployLocal.s.sol --rpc-url http://127.0.0.1:8546 --broadcast
cd sdk/python && python scripts/e2e.py
```

`scripts/e2e.py` runs the full flow with anvil accounts 0-5: principals authorize operators, the
operators register identities, the client operator creates a two-milestone job ($100 + $150.50) from USDC strings, the
provider accepts it, submits both milestones and the client approves them, then it asserts
`Completed`, the $250.50 payout, two positive reputation entries and the audit trail. A permit phase
(`scripts/e2e_permit.py`) signs an EIP-2612 permit and calls `create_job_with_permit` with no prior
approval, then has the provider accept and submit, advances the anvil clock 8 days and claims the
milestone through `claim_approval`. A timeout phase (`scripts/e2e_timeouts.py`) closes with two
scenarios: the client goes silent after one submission and anvil account 5, a bystander, calls
`settle_expired` so the submitted milestone pays the provider while the pending one refunds the
client; and an offer the provider never accepted is cancelled for a full refund. Override `RPC_URL`
and `ADDRESSES_JSON` to point it elsewhere; it exits non-zero if any check fails.

Two notes on that run:

- `test/mocks/ERC20Mock.sol` (the token `DeployLocal` deploys) has no `permit`, so the permit phase
  deploys `contracts/ERC20PermitMock.sol` plus a second escrow bound to it. The prebuilt artifact
  lives in `scripts/artifacts/`; rebuild it with
  `forge build --contracts sdk/python/contracts --out sdk/python/.forge-out`.
- The escrow wraps its audit-log, reputation and fee-router calls in `try/catch`, so
  `eth_estimateGas` returns a limit at which those inner calls run out of gas and are silently
  swallowed. The SDK therefore sends `max(1.5 * estimate, estimate + 75_000)`; see
  `GAS_BUFFER_NUMERATOR` in `nexusweb3/tx.py`.
