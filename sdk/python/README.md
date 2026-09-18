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
principal.usdc.approve(addresses.escrow, 250_000_000)         # 2. or use create_job_with_permit
principal.kill_switch.register(1_000_000_000, 50, 86_400)     # 3. optional spending guard

agent = NexusClient(w3, addresses, Account.from_key(HOT_KEY))  # the hot key holds nothing
agent.identity.register(principal.address, "my-agent", "ipfs://profile.json", 1)
job = agent.escrow.create_job(CreateParams(
    client=principal.address, provider=PROVIDER, milestone_amounts=[100_000_000, 150_000_000],
    deadline=int(time.time()) + 7 * 86_400, terms_hash="TERMS_V1",
))
agent.escrow.approve_milestone(job.job_id, 0)                  # provider paid, reputation written
```

Sub-clients: `access`, `identity`, `reputation`, `kill_switch`, `audit_log`, `escrow`, `fee_router`,
`usdc`. Reads need no account; writes sign, send and wait for the receipt, returning a `TxResult`
with `hash`, `receipt` and `job_id` / `log_id` decoded from `JobCreated` / `ActionLogged`.

Structs come back as dataclasses (`AgentProfile`, `Stats`, `AgentConfig`, `Job`, `Milestone`,
`ActionLog`) and enums as readable strings (`JobStatus.OPEN.value == "Open"`, `Tier.GOLD`).
`bytes32` action types round-trip through `to_bytes32` / `from_bytes32`.

### Permit (EIP-2612)

```python
from nexusweb3 import sign_permit, BASE_USDC_PERMIT_VERSION

v, r, s = sign_permit(account, w3, addresses.payment_token, addresses.escrow,
                      total, deadline, version=BASE_USDC_PERMIT_VERSION)  # Base USDC uses "2"
client.escrow.create_job_with_permit(params, deadline, v, r, s)
```

## CLI

```bash
export NEXUS_RPC_URL=http://127.0.0.1:8546
export NEXUS_ADDRESSES_JSON=../../deployments/v2-local-py.json
export NEXUS_PRIVATE_KEY=0x...        # the operator hot key
export NEXUS_PRINCIPAL=0x...          # the agent principal it acts for

nexusweb3 identity register --name my-agent --uri ipfs://profile.json --type 1
nexusweb3 identity get --agent 0xPRINCIPAL
nexusweb3 reputation get --agent 0xPRINCIPAL
nexusweb3 escrow create --provider 0xPROVIDER --amounts 100,150 --deadline-hours 168
nexusweb3 escrow submit --job-id 0 --index 0 --hash DELIVERABLE_0
nexusweb3 escrow approve --job-id 0 --index 0
nexusweb3 escrow claim --job-id 0 --index 0      # provider, after the 7-day review window
nexusweb3 escrow get --job-id 0
nexusweb3 escrow list --agent 0xPRINCIPAL
nexusweb3 killswitch status --agent 0xPRINCIPAL
nexusweb3 auditlog list --agent 0xPRINCIPAL --limit 20
```

Every command prints JSON and exits non-zero on error. Amounts are human USDC (`100,150` = $250).

## Tests

```bash
pytest -q                 # 31 unit tests, no chain needed
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

`scripts/e2e.py` runs the full flow with anvil accounts 0-4: principals authorize operators, the
operators register identities, the client operator creates a two-milestone job ($100 + $150), the
provider submits and the client approves both, then it asserts `Completed`, the $250 payout, two
positive reputation entries and the audit trail. A final phase signs an EIP-2612 permit and calls
`create_job_with_permit` with no prior approval, then has the provider submit, advances the anvil
clock 8 days and claims the milestone through `claim_approval`, asserting the payout. Override `RPC_URL` and `ADDRESSES_JSON` to point it
elsewhere; it exits non-zero if any check fails.

Two notes on that run:

- `test/mocks/ERC20Mock.sol` (the token `DeployLocal` deploys) has no `permit`, so the permit phase
  deploys `contracts/ERC20PermitMock.sol` plus a second escrow bound to it. The prebuilt artifact
  lives in `scripts/artifacts/`; rebuild it with
  `forge build --contracts sdk/python/contracts --out sdk/python/.forge-out`.
- The escrow wraps its audit-log, reputation and fee-router calls in `try/catch`, so
  `eth_estimateGas` returns a limit at which those inner calls run out of gas and are silently
  swallowed. The SDK therefore sends `max(1.5 * estimate, estimate + 75_000)`; see
  `GAS_BUFFER_NUMERATOR` in `nexusweb3/tx.py`.
