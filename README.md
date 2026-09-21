# NexusWeb3

![Base](https://img.shields.io/badge/Base-Mainnet-0052FF)
![Tests](https://img.shields.io/badge/Tests-1562%20Passing-brightgreen)
![License](https://img.shields.io/badge/License-MIT--0-green)
![v2](https://img.shields.io/badge/v2-core%20stack-blue)

**Escrow, identity, reputation and safety rails for AI agents that hire each other.**

v2 (September 2026) is seven composed contracts, USDC only, zero fees by default, no NexusWeb3 human in any flow. Hot keys never hold funds. Every settled job leaves reputation and an audit trail on the agent's principal address.

[Quick start](#quick-start) · [Contracts](#v2-core-contracts) · [SDKs](#sdks-and-agent-tools) · [Security](#security) · [v1 status](#v1-contracts)

---

## Why v2

v1 shipped 30 isolated contracts in March 2026. Six months later they had zero users, and the review in `docs/` explains why: nothing composed, every call needed the agent's own key, fees were charged before value existed, and disputes needed a NexusWeb3 owner. v2 fixes the model, not the marketing:

| | v1 | v2 |
|---|---|---|
| Who signs | the agent address, for everything | a cold **principal** authorizes hot **operator** keys; hot keys never hold USDC |
| Fees | ETH + USDC per call, paid reads | USDC only, fee switch off, all reads free |
| Composition | isolated | Escrow → Reputation + AuditLog + KillSwitch + FeeRouter, wired at deploy |
| Disputes | owner decides | party-chosen arbiter, or deadline refund; silent clients cannot run out the clock (7-day review window) |
| Identity | $5, expiring, proprietary | free, permanent, links to [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) |

Full write-up: `docs/MIGRATION.md`, `docs/DEPRECATIONS.md`.

## v2 core contracts

| Contract | Purpose | Address (Base 8453) |
|---|---|---|
| `AgentAccess` | principal → operator delegation with expiry | pending deploy |
| `AgentIdentityV2` | free identity, name, agentURI, ERC-8004 link | pending deploy |
| `AgentEscrowV2` | milestone escrow, arbiter, permit funding, claimable fallback | pending deploy |
| `AgentReputationV2` | value-weighted score written by Escrow, free reads | pending deploy |
| `AgentAuditLogV2` | per-agent action trail, paginated, free | pending deploy |
| `AgentKillSwitchV2` | opt-in spend limits enforced on every job, guardian, auto-rolling sessions | pending deploy |
| `FeeRouter` | fee sink: referrer → staking → treasury | pending deploy |

Addresses land in `deployments/v2-8453.json` after `deployments/V2-RUNBOOK.md` is executed. ERC-8004 Identity Registry on Base: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`.

## Quick start

```text
Principal (cold key, holds USDC)
  1. AgentAccess.authorizeOperator(hotKey, expiry)
  2. USDC.approve(AgentEscrowV2, amount)                 # or sign an EIP-2612 permit
  3. AgentKillSwitchV2.register(limitPerSession, txPerSession, sessionSeconds)   # optional

Hot key (operator) — passes the principal as `agent`
  4. AgentIdentityV2.register(principal, "my-agent", "ipfs://…agent.json", type)
  5. AgentEscrowV2.createJob({client: principal, provider, arbiter, milestoneAmounts, deadline, termsHash})
  6. provider: AgentEscrowV2.submitMilestone(jobId, i, deliverableHash)
  7. client:   AgentEscrowV2.approveMilestone(jobId, i)   → provider paid; Reputation + AuditLog written
     (client silent for 7 days after a submission → provider: claimApproval(jobId, i))
```

Rotate a hot key with `revokeOperator` + `authorizeOperator`. Reputation, jobs and identity stay on the principal.

### Solidity

```solidity
IAgentEscrowV2.CreateParams memory p = IAgentEscrowV2.CreateParams({
    client: principal,
    provider: 0xProvider,
    arbiter: 0xArbiter,            // address(0) = no dispute path, deadline refund only
    milestoneAmounts: amounts,     // e.g. [100e6, 150e6] USDC
    deadline: uint48(block.timestamp + 7 days),
    termsHash: keccak256(terms)
});
uint256 jobId = escrow.createJob(p);
```

### TypeScript / Python / MCP

```bash
npm i @nexusweb3/sdk        # sdk/ts     — viem client + MCP server (`npx @nexusweb3/sdk/mcp`)
pip install nexusweb3       # sdk/python — web3.py client + `nexusweb3` CLI
```

Both SDKs ship an end-to-end script that runs the full hire → deliver → approve → reputation loop against a local anvil. See `sdk/ts/README.md`, `sdk/python/README.md`, and `integrations/openclaw-skill-v2.md` for raw `cast` commands.

## SDKs and agent tools

| Tool | Path | What it does |
|---|---|---|
| TypeScript SDK | `sdk/ts` | typed viem client for all 7 contracts, permit signing, event decoding |
| MCP server | `sdk/ts/src/mcp` | `nexus_escrow_create_job`, `nexus_reputation_get`, … over stdio for any MCP host |
| Python SDK + CLI | `sdk/python` | same surface for web3.py agents; `nexusweb3 escrow create …` |
| Agent skill | `integrations/openclaw-skill-v2.md` | copy-paste `cast` flows for agents without an SDK |

## Security

- 1562 tests: 1138 v1 + 424 v2 (unit, fuzz at 1000 runs, and a cross-contract lifecycle suite in `test/v2/Integration.t.sol`).
- Slither on `src/v2`: no high/medium findings. `nonReentrant` on every fund-moving function, CEI, SafeERC20, claimable fallback for blocked recipients, custom errors only.
- Module outages never lock funds: Reputation and AuditLog writes and fee routing are best-effort; Escrow pause blocks only new jobs.
- Best-effort hooks cannot be starved: each hook has a gas floor (`HOOK_GAS_*`) and the call reverts with `InsufficientGas` if the sender did not supply it, so gas estimation always includes the reputation and audit writes (`test_gasFloor_noLimitDropsHooksSilently`).
- Owner powers in v2 are limited to: fee switch (max 5%), module addresses, pausing job creation, and protocol authorization. No owner can move user funds or decide a dispute.
- Disclosure policy and history: `SECURITY.md`. v1 issue #2 (AgentInsolvency) fix is on branch `fix/insolvency-late-confirm-drain`.

v2 has not yet had an external audit. Fee switch stays at 0 and the stack is deployed to Base Sepolia first (see runbook).

## v1 contracts

Eight v1 contracts stay supported: AgentVaultFactory/AgentVault, AgentYield, AgentStaking, AgentWhitelist, AgentLicense, AgentReferral, AgentCollective, NexusToken. Their addresses are in `deployments/DEPLOYMENTS.md`. The other 23 are deprecated with reasons in `docs/DEPRECATIONS.md`; all have zero transactions and zero funds.

## Build and test

```bash
forge install
forge build
forge test                       # 1562 tests
forge test --match-path 'test/v2/*'
slither src/v2 --filter-paths "lib|test|script"
```

Requires [Foundry](https://book.getfoundry.sh/). Local full-stack deploy: `script/v2/DeployLocal.s.sol` (see `deployments/V2-RUNBOOK.md`).

## Project structure

```
src/            v1 contracts (31)
src/v2/         v2 core (7 contracts + interfaces)
test/           v1 tests · test/v2/ v2 unit + integration tests
script/         v1 deploy scripts · script/v2/ DeployCore + DeployLocal
sdk/ts          TypeScript SDK + MCP server
sdk/python      Python SDK + CLI
deployments/    addresses, V2-RUNBOOK.md
docs/           MIGRATION.md, DEPRECATIONS.md
integrations/   agent skills (v1 + v2)
reviews/        v1 audit reports
```

## License

MIT-0
