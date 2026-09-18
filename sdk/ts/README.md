# @nexusweb3/sdk

TypeScript SDK and MCP server for the NexusWeb3 **v2** agent protocol stack on Base:
`AgentAccess`, `AgentIdentityV2`, `AgentReputationV2`, `AgentKillSwitchV2`, `AgentAuditLogV2`,
`FeeRouter` and `AgentEscrowV2`.

Built on [viem](https://viem.sh). Every ABI is generated from the compiled Foundry artifacts, so
argument and return types come straight from the contracts.

## Install

```bash
npm install @nexusweb3/sdk viem
```

## Quickstart

The v2 model: an agent **principal** (cold key, holds funds and identity) authorizes **operator**
hot keys, and every write takes the principal as an explicit parameter. The hot key never holds USDC.

```ts
import { createNexusClient, loadAddresses } from '@nexusweb3/sdk';
import { createPublicClient, createWalletClient, http, parseUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';
import deployment from './deployments/v2-8453.json' with { type: 'json' };

const addresses = loadAddresses(deployment);
const publicClient = createPublicClient({ chain: base, transport: http() });
const hotKey = createWalletClient({ account: privateKeyToAccount(process.env.HOT_KEY), chain: base, transport: http() });
const nexus = createNexusClient({ publicClient, walletClient: hotKey, addresses });

await nexus.identity.register(PRINCIPAL, 'atlas', 'https://…/atlas.json', 1);            // step 4
const job = await nexus.escrow.createJob({                                               // step 5
  client: PRINCIPAL, provider: PROVIDER, milestoneAmounts: [parseUnits('250', 6)],
  deadline: Math.floor(Date.now() / 1000) + 7 * 24 * 3600,
});
await nexus.escrow.approveMilestone(job.jobId, 0);                                       // step 7
```

Steps 1-3 of `docs/MIGRATION.md` are signed by the principal itself, not the hot key:

```ts
const cold = createNexusClient({ publicClient, walletClient: principalWallet, addresses });
await cold.access.authorizeOperator(hotKey.account.address);            // 1. authorize the hot key
await cold.usdc.approve(addresses.escrow, parseUnits('1000', 6));       // 2. fund allowance
await cold.killSwitch.register(parseUnits('500', 6), 20, 86_400);       // 3. optional spend guard
```

Read-only use needs no wallet at all: `createNexusClient({ publicClient, addresses })`.

### Namespaces

| Namespace | What it covers |
|---|---|
| `access` | `authorizeOperator`, `revokeOperator`, `isOperatorFor`, `operatorExpiry` |
| `identity` | `register`, `setAgentURI`, `getAgent`, `isRegistered`, `getAgentByName`, `linkERC8004` |
| `reputation` | `getScore`, `getTier` (`'BRONZE' \| 'SILVER' \| 'GOLD' \| 'PLATINUM'`), `getStats` |
| `killSwitch` | `register`, `setGuardian`, `kill`, `pause`, `unpause`, `resume`, `isActive`, `getConfig`, `remainingSpend` |
| `auditLog` | `log` (string action type → bytes32), `getAgentLogs` (decoded back to strings) |
| `escrow` | `createJob`, `createJobWithPermit`, `submitMilestone`, `approveMilestone`, `claimApproval`, `rejectMilestone`, `cancelJob`, `dispute`, `resolve`, `refundExpired`, `withdrawClaimable`, `getJob`, `getMilestones`, `getJobsOf`, `expiryOf` |
| `usdc` | `approve`, `transfer`, `balanceOf`, `allowance` |

Writes wait for the receipt and return `{ hash, receipt }`; `createJob*` also returns `jobId` and
`auditLog.log` returns `logId`, both decoded from the receipt logs. Enums come back as string
unions, never numbers. Amounts are `bigint` in token base units (USDC has 6 decimals).

A client who neither approves nor rejects is not a dead end: seven days after a submission the
provider can take the milestone with `escrow.claimApproval(jobId, index)`, and `escrow.expiryOf`
returns `max(deadline, last submission + review window)` — the moment `refundExpired` opens.

### Gas buffer

The escrow writes reputation and the audit log through `try/catch` hooks, so a transaction still
succeeds when those inner calls run out of gas — and `eth_estimateGas` will happily return a limit
that silently skips them (`submitMilestone`: 211k estimated, 248k actually needed). Every write
therefore goes out with `estimate × 1.5`; unused gas is refunded. Override with
`createNexusClient({ …, gasMultiplier: 1.2 })`.

### Pay with a permit instead of an approval

```ts
import { signPermit } from '@nexusweb3/sdk';

const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
const sig = await signPermit({ walletClient: principalWallet, publicClient, token: addresses.paymentToken,
  owner: PRINCIPAL, spender: addresses.escrow, value: total, deadline });
await nexus.escrow.createJobWithPermit({ client: PRINCIPAL, provider, milestoneAmounts, deadline: jobDeadline }, deadline, sig);
```

`signPermit` reads `name()`, `nonces()` and the chain id itself, and takes the EIP-712 version from
the token's ERC-5267 `eip712Domain()` when it has one (USDC does not — it falls back to `"2"`).
`createJobWithPermit` must be sent by the client principal, since the permit signer and the payer
are the same address.

## MCP server

Exposes the stack to Claude Desktop, OpenClaw and any other MCP client over stdio.

```json
{
  "mcpServers": {
    "nexusweb3": {
      "command": "npx",
      "args": ["-y", "@nexusweb3/sdk/mcp"],
      "env": {
        "NEXUS_RPC_URL": "https://mainnet.base.org",
        "NEXUS_ADDRESSES_JSON": "/abs/path/to/deployments/v2-8453.json",
        "NEXUS_PRIVATE_KEY": "0x… operator hot key (omit for read-only)",
        "NEXUS_PRINCIPAL": "0x… agent principal the hot key acts for"
      }
    }
  }
}
```

`NEXUS_PRINCIPAL` defaults to the hot key's own address. Without `NEXUS_PRIVATE_KEY` the server
starts read-only and the write tools refuse with an explanatory error instead of failing silently.

| Tool | Kind |
|---|---|
| `nexus_identity_get`, `nexus_reputation_get`, `nexus_killswitch_status` | read |
| `nexus_escrow_get_job`, `nexus_escrow_list_jobs`, `nexus_auditlog_list` | read |
| `nexus_access_check_operator` | read |
| `nexus_identity_register`, `nexus_access_authorize_operator` | write |
| `nexus_escrow_create_job`, `nexus_escrow_submit_milestone` | write |
| `nexus_escrow_approve_milestone`, `nexus_escrow_claim_approval` | write |

Token amounts are passed as decimal strings in base units (`"100000000"` = 100 USDC). Every tool
returns JSON text, and every failure comes back as `isError: true` content rather than a transport
error.

## Development

```bash
npm install
npm run abi:sync   # regenerate src/abis/*.ts from ../../out (run `forge build` first)
npm run build
npm test
```

### End-to-end against anvil

From the repository root, in a second terminal:

```bash
anvil --port 8545 --silent &
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  DEPLOY_JSON_PATH=deployments/v2-local-ts.json \
  forge script script/v2/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd sdk/ts && npm run e2e
```

The script authorizes operators, registers identities, runs a two-milestone job to `Completed`,
and asserts settlement, reputation, tier and audit-log output. It then exercises `signPermit` +
`createJobWithPermit` with no prior approval, and finally pushes anvil's clock past the review
window to claim an ignored milestone. Override `RPC_URL` and `ADDRESSES_JSON` to point it at Base
Sepolia instead (see `deployments/V2-RUNBOOK.md`), minus the two time-travel checks.

The local deploy funds the escrow with `PermitToken`, a 6-decimal EIP-2612 mock USDC, so the permit
leg runs against the real deployment.
