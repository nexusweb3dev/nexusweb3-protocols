# NexusWeb3 SDKs

Two clients for the v2 contracts, same surface, same end-to-end test. Pick the language your agent runs in.

| | TypeScript | Python |
|---|---|---|
| Path | `sdk/ts` | `sdk/python` |
| Package | `@nexusweb3/sdk` | `nexusweb3` |
| Stack | viem 2, Node ≥ 20 | web3.py ≥ 7, Python ≥ 3.10 |
| Extras | MCP server (`nexusweb3-mcp`, 13 tools) | CLI (`nexusweb3`) |
| Unit tests | `npm test` (23) | `pytest` (31) |
| End-to-end | `npm run e2e` (21 checks) | `python scripts/e2e.py` (34 checks) |

Both wrap all seven contracts: `access`, `identity`, `reputation`, `killSwitch`, `auditLog`, `feeRouter`, `escrow`, plus a minimal `usdc` helper and EIP-2612 permit signing. Writes wait for the receipt and decode the relevant event (`jobId`, `logId`). Enums come back as strings. Gas is sent at 1.5× the estimate so the escrow's gas-floored hooks are always funded.

## Addresses

Both SDKs load a `deployments/v2-<chainId>.json` produced by `script/v2/DeployCore.s.sol` (or `DeployLocal.s.sol` for anvil). Until the Base deploy is executed (see `../deployments/V2-RUNBOOK.md`) use a local chain:

```bash
anvil --port 8545 --silent &
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
DEPLOY_JSON_PATH=deployments/v2-local.json \
forge script script/v2/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Principal and operator keys

The SDKs are written for the v2 key model: a cold **principal** holds USDC and identity and authorizes a hot **operator** key once; the operator then signs everything, passing the principal's address as the `agent`/`client`/`provider` parameter. Kill-switch configuration is the one exception and must be signed by the principal (or its guardian). Full flow: `../docs/MIGRATION.md`.

## Running the end-to-end tests against a testnet

Set `RPC_URL` and `ADDRESSES_JSON` to a Base Sepolia deployment and fund the five accounts the scripts use (they are the default anvil accounts; replace the keys via env if you prefer your own). The Python and TypeScript scripts run the same scenario: authorize operators, register identities, run a two-milestone job to completion, verify reputation and audit entries, then fund a job by permit and exercise the 7-day review-window claim by advancing chain time, which only works on anvil.

## Regenerating ABIs

ABIs are generated from `out/` after `forge build`:

```bash
cd sdk/ts && npm run abi:sync
cd sdk/python && python scripts/sync_abis.py
```

Commit the generated files; CI checks they match the contracts.
