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

## Amounts are USDC, not base units

Every amount you pass to this SDK, its CLI counterpart and its MCP tools is a **USDC figure in
dollars**: `'100.50'` is one hundred dollars fifty. There is no 1e6 conversion to do by hand.

```ts
import { formatUsdc, parseUsdc } from '@nexusweb3/sdk';

await nexus.usdc.approve(addresses.escrow, '1000');        // 1000 USDC
await nexus.killSwitch.register('500', 20, 86_400);        // 500 USDC per session
parseUsdc('100.50');                                       // 100500000n, when you need base units
```

Reads return `bigint` base units, because that is what the chain stores — `formatUsdc` turns one
back into a dollar figure. A `bigint` passed *in* is therefore read as base units too: the type,
not the digits, decides, so `100n` is 0.0001 USDC while `'100'` is one hundred dollars. Anything
finer than six decimal places is rejected rather than silently truncated.

## Quickstart

The v2 model: an agent **principal** (cold key, holds funds and identity) authorizes **operator**
hot keys, and every write takes the principal as an explicit parameter. The hot key never holds USDC.

```ts
import { createNexusClient, loadAddresses } from '@nexusweb3/sdk';
import { createPublicClient, createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';
import deployment from './deployments/v2-8453.json' with { type: 'json' };

const addresses = loadAddresses(deployment);
const publicClient = createPublicClient({ chain: base, transport: http() });
const hotKey = createWalletClient({ account: privateKeyToAccount(process.env.HOT_KEY), chain: base, transport: http() });
const nexus = createNexusClient({ publicClient, walletClient: hotKey, addresses });

await nexus.identity.register(PRINCIPAL, 'atlas', 'https://…/atlas.json', 1);            // step 4
const job = await nexus.escrow.createJob({                                               // step 5
  client: PRINCIPAL, provider: PROVIDER, milestoneAmounts: ['250'],       // 250 USDC
  deadline: Math.floor(Date.now() / 1000) + 7 * 24 * 3600,
});
await providerNexus.escrow.acceptJob(job.jobId);                                         // step 6, provider side
await nexus.escrow.approveMilestone(job.jobId, 0);                                       // step 7
```

`createJob` only posts an **offer**: the funds are locked but the provider is not bound to
anything yet. `escrow.acceptJob(jobId)`, signed by the provider or one of its operators, is what
makes the job live. Before it lands `submitMilestone`, `approveMilestone` and `dispute` all revert
with `NotAccepted`, and the client can walk away with `escrow.cancelJob(jobId)` for a full refund.
Acceptance must happen before the job deadline.

Steps 1-3 of `docs/MIGRATION.md` are signed by the principal itself, not the hot key:

```ts
const cold = createNexusClient({ publicClient, walletClient: principalWallet, addresses });
await cold.access.authorizeOperator(hotKey.account.address);            // 1. authorize the hot key
await cold.usdc.approve(addresses.escrow, '1000');                      // 2. fund allowance
await cold.killSwitch.register('500', 20, 86_400);                      // 3. optional spend guard
```

Read-only use needs no wallet at all: `createNexusClient({ publicClient, addresses })`.

### Namespaces

| Namespace | What it covers |
|---|---|
| `access` | `authorizeOperator`, `revokeOperator`, `renounceOperator`, `isOperatorFor`, `operatorExpiry` |
| `amount` | `parseUsdc`, `formatUsdc`, `toBaseUnits`, `USDC_DECIMALS` (top-level exports, not a namespace) |
| `identity` | `register`, `setAgentURI`, `getAgent`, `isRegistered`, `getAgentByName`, `linkERC8004`, `registryEpoch` |
| `reputation` | `getScore`, `getTier` (`'BRONZE' \| 'SILVER' \| 'GOLD' \| 'PLATINUM'`), `getStats` |
| `killSwitch` | `register`, `setGuardian`, `kill`, `pause`, `unpause`, `resume`, `resetSession`, `isActive`, `getConfig`, `remainingSpend` |
| `auditLog` | `log` (string action type → bytes32), `getAgentLogs` (decoded back to strings) |
| `escrow` | `createJob`, `createJobWithPermit`, `acceptJob`, `submitMilestone`, `approveMilestone`, `claimApproval`, `rejectMilestone`, `cancelJob`, `dispute`, `resolve`, `settleExpired`, `withdrawClaimable`, `getJob`, `getMilestones`, `getJobsOf`, `expiryOf` |
| `usdc` | `approve`, `transfer`, `balanceOf`, `allowance` |

Writes wait for the receipt and return `{ hash, receipt }`; `createJob*` also returns `jobId` and
`auditLog.log` returns `logId`, both decoded from the receipt logs. Enums come back as string
unions, never numbers.

`access.renounceOperator(agent)` is signed by the operator itself, so a hot key that may have
leaked can cut itself off without waiting for the principal. Agent names accept only lowercase
`a-z`, digits, `-`, `_` and `.`; anything else reverts with `InvalidName`.

`killSwitch.resetSession` is **principal-only**: it restores spending headroom, so neither an
operator nor the restrict-only guardian may call it. Sign it with the agent principal itself or it
reverts with `NotPrincipal`. `linkERC8004` rejects a zero `agentId` (`InvalidERC8004Id`), and a
link written before the owner last repointed the contract at another registry reads back as
unlinked — compare `identity.registryEpoch()` if you cache links off-chain.

### When the counterparty goes quiet

A client who neither approves nor rejects is not a dead end: seven days after a submission the
provider can take the milestone with `escrow.claimApproval(jobId, index)`, and `escrow.expiryOf`
returns `max(deadline, last submission + review window)` — the moment `settleExpired` opens.

`escrow.settleExpired(jobId)` is permissionless and replaces the old refund-only path. It splits by
state rather than by who shows up: every **Submitted** milestone vests to the provider, every
**Pending** one refunds the client. It also closes out a `Disputed` job whose arbiter never ruled,
30 days after `job.disputedAt`. The result carries `toProvider` and `toClient` decoded from
`JobExpired`.

```ts
const settled = await nexus.escrow.settleExpired(jobId);   // anyone may call this
console.log(settled.toProvider, settled.toClient);

const swept = await nexus.escrow.withdrawClaimable(PRINCIPAL, TREASURY);  // (account, to)
console.log(formatUsdc(swept.amount));
```

`withdrawClaimable` takes the account whose parked balance is being swept and the address that
receives the tokens; it is signed by that account or one of its operators, and `to` must not be the
zero address. `job.acceptedAt`, `job.disputedAt`, `job.everSubmitted` and `milestone.rejections`
are exposed on the decoded structs. A milestone tolerates `MAX_REJECTIONS` (3) rejections, each
only inside the review window (`ReviewWindowClosed` afterwards), and a client/provider pair can
generate at most `MAX_REPUTATION_PER_PAIR` (10) reputation entries.

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
  owner: PRINCIPAL, spender: addresses.escrow, value: '250', deadline });
await nexus.escrow.createJobWithPermit({ client: PRINCIPAL, provider, milestoneAmounts: ['250'], deadline: jobDeadline }, deadline, sig);
```

`signPermit` reads `name()`, `nonces()` and the chain id itself, and works out the EIP-712 domain
version with `resolveEip712Version`: the token's ERC-5267 `eip712Domain()` when it has one, then
`KNOWN_EIP712_VERSIONS` for deployments that do not (Base and Base Sepolia USDC sign with `"2"`
and expose no descriptor), then `"1"`, which every other EIP-2612 token uses. Pass `version` to
override. Signing under the wrong version yields a signature the token silently rejects, which is
why detection is preferred over a blanket default. `createJobWithPermit` must be sent by the
client principal, since the permit signer and the payer are the same address.

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
`nexus_access_authorize_operator` is hidden unless `NEXUS_MCP_ALLOW_PRINCIPAL_WRITES=1`, because it
hands another key full authority and the model driving the server reads untrusted on-chain text.
`NEXUS_MCP_MAX_JOB_AMOUNT` caps the total of a single job in base units.

| Tool | Kind |
|---|---|
| `nexus_identity_get`, `nexus_reputation_get`, `nexus_killswitch_status` | read |
| `nexus_escrow_get_job`, `nexus_escrow_list_jobs`, `nexus_auditlog_list` | read |
| `nexus_access_check_operator` | read |
| `nexus_identity_register`, `nexus_access_authorize_operator` | write |
| `nexus_access_renounce_operator` | write |
| `nexus_escrow_create_job`, `nexus_escrow_accept_job`, `nexus_escrow_submit_milestone` | write |
| `nexus_escrow_approve_milestone`, `nexus_escrow_claim_approval` | write |
| `nexus_escrow_settle_expired`, `nexus_escrow_withdraw_claimable` | write |

Every amount crossing the tool boundary, in or out, is a USDC figure in dollars (`"100.50"`), never
base units — including `NEXUS_MCP_MAX_JOB_AMOUNT`, which the startup banner echoes back in USDC so
a value copied from an older base-unit config is obvious immediately. Every tool returns JSON text,
and every failure comes back as `isError: true` content rather than a transport error.

`nexus_access_renounce_operator` is deliberately **not** behind `NEXUS_MCP_ALLOW_PRINCIPAL_WRITES`:
it only ever removes the signing hot key's own authority, so the worst a prompt injection achieves
is making the agent stop working. `nexus_access_authorize_operator` grants authority and stays
gated.

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

The script authorizes operators, registers identities, has the provider accept the offer, runs a
two-milestone job to `Completed`, and asserts settlement, reputation, tier and audit-log output. It
then exercises `signPermit` + `createJobWithPermit` with no prior approval, and pushes anvil's clock
past the review window to claim an ignored milestone. Two timeout scenarios close it out: a
bystander settling an expired job so the submitted milestone pays the provider and the pending one
refunds the client, and a job cancelled before acceptance for a full refund. Override `RPC_URL` and
`ADDRESSES_JSON` to point it at Base Sepolia instead (see `deployments/V2-RUNBOOK.md`), minus the
time-travel checks.

The local deploy funds the escrow with `PermitToken`, a 6-decimal EIP-2612 mock USDC, so the permit
leg runs against the real deployment.
