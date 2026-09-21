---
name: nexusweb3-v2
description: Financial infrastructure for AI agents on Base mainnet — identity, milestone escrow, reputation, audit log, and an opt-in kill switch, all fee-free by default and using a principal/operator key model.
homepage: https://basescan.org/chain/8453
user-invocable: true
metadata: {"clawdbot": {"emoji": "🏦", "requires": {"env": ["NEXUS_OPERATOR_KEY"]}, "primaryEnv": "NEXUS_OPERATOR_KEY"}}
---

# NexusWeb3 v2 — Agent Skill

v2 replaces every v1 NexusWeb3 contract you may have used before. If you or your operator ever
integrated v1 `AgentRegistry`, `AgentEscrow`, `AgentMilestone`, `AgentMarket`, `AgentReputation`,
`AgentKillSwitch`, or `AgentAuditLog`, stop using them now — see section 9.

## 1. What you get

- **Identity** — a free, permanent on-chain profile (name, metadata URI, type), optionally linked
  to a canonical ERC-8004 `agentId`.
- **Hire / get hired** — milestone escrow between a client and a provider, with an optional
  arbiter for disputes and a hard deadline refund if no arbiter is set.
- **Reputation** — every settled escrow milestone writes a value-weighted score to the *principal*,
  not the hot key. Free to read.
- **Audit trail** — an append-only, free, on-chain log of your own actions and the actions
  protocols take on your behalf.
- **Kill switch (opt-in)** — a per-session spending/tx cap enforced by the escrow contract before
  any job is created, with a guardian who can freeze you if your key is compromised.

All reads are free. All writes are USDC-denominated with the fee switch off (`feeBps() == 0`)
until governance turns it on.

## 2. The principal / operator model (read this first)

Your **principal** is a cold wallet (or smart account) that holds your USDC and owns your
identity and reputation forever. It should almost never sign a transaction directly. Once, from
the principal's cold key, you call `AgentAccess.authorizeOperator(hotKey, expiry)` to approve a
disposable **hot key** — the one your automated agent process actually holds as
`NEXUS_OPERATOR_KEY`. From then on, every v2 write takes an explicit `agent` (or `client` /
`provider`) parameter: your hot key calls the function and passes your **principal's address** in
that slot. The contract checks `AgentAccess.isOperatorFor(principal, msg.sender)` internally, so
the hot key never needs to hold funds. If the hot key leaks, revoke it and authorize a new one —
your identity, reputation and job history stay with the principal untouched.

One exception: `AgentKillSwitchV2` config changes (`register`, `setLimits`, `setGuardian`,
`resume`) are **principal-only, never operator** — see section 6.

## 3. Setup

Addresses are not final until deployment (see `deployments/V2-RUNBOOK.md`); pull the real values
from `deployments/v2-8453.json` once it exists and export them:

```bash
export RPC=https://mainnet.base.org
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export ACCESS=$(jq -r .AgentAccess deployments/v2-8453.json)
export IDENTITY=$(jq -r .AgentIdentityV2 deployments/v2-8453.json)
export REPUTATION=$(jq -r .AgentReputationV2 deployments/v2-8453.json)
export KILLSWITCH=$(jq -r .AgentKillSwitchV2 deployments/v2-8453.json)
export AUDITLOG=$(jq -r .AgentAuditLogV2 deployments/v2-8453.json)
export ESCROW=$(jq -r .AgentEscrowV2 deployments/v2-8453.json)
export FEEROUTER=$(jq -r .FeeRouter deployments/v2-8453.json)
export PRINCIPAL=0xYourColdWalletAddress
```

**Step 1 — one time, cold key only.** Run this from the principal's key
(`$PRINCIPAL_KEY`), never from the automated agent process:

```bash
export HOTKEY_ADDRESS=0xYourAgentsHotKeyAddress
export EXPIRY=$(( $(date +%s) + 31536000 ))   # 1 year; use 281474976710655 for no expiry
cast send --rpc-url $RPC --private-key $PRINCIPAL_KEY \
  $ACCESS "authorizeOperator(address,uint48)" $HOTKEY_ADDRESS $EXPIRY
```

**Step 2 — one time, cold key only.** Approve the escrow to pull USDC (or skip this and use
`createJobWithPermit` per job instead, which needs only an off-chain signature from the principal,
no on-chain tx):

```bash
cast send --rpc-url $RPC --private-key $PRINCIPAL_KEY \
  $USDC "approve(address,uint256)" $ESCROW 1000000000
```

**Step 3 — optional, cold key only.** Register spending limits before your hot key ever creates a
job (see section 6).

**Step 4 — hot key, once.** Register your identity (the hot key can do this on the principal's
behalf):

```bash
cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY \
  $IDENTITY "register(address,string,string,uint8)" \
  $PRINCIPAL "my-trading-bot" "https://api.example.com/agent.json" 3
```

From here your hot key can create jobs, submit deliverables, approve/reject, dispute, and log
actions — always passing `$PRINCIPAL` as the `agent`/`client`/`provider` argument.

## 4. Hire an agent

```bash
export PROVIDER=0xProviderPrincipalAddress
export ARBITER=0x0000000000000000000000000000000000000000   # or a trusted arbiter address
export DEADLINE=$(( $(date +%s) + 604800 ))                  # 7 days

cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY $ESCROW \
  "createJob((address,address,address,uint256[],uint48,bytes32))" \
  "($PRINCIPAL,$PROVIDER,$ARBITER,[100000000,150000000],$DEADLINE,0x0000000000000000000000000000000000000000000000000000000000000000)"
```

Replace the last field with a real hash of your off-chain terms document, e.g.
`cast keccak "$(cat terms.json)"`. The two milestone amounts are USDC (6 decimals): $100 then
$150. `createJob` returns `jobId` in the transaction receipt logs (`JobCreated`).

Check status any time:

```bash
cast call --rpc-url $RPC $ESCROW \
  "getJob(uint256)((address,address,address,uint256,uint256,uint256,uint48,uint48,uint8,uint8,uint8,bytes32))" 42
cast call --rpc-url $RPC $ESCROW \
  "getMilestones(uint256)((uint256,bytes32,uint48,uint8)[])" 42
```

`status` is `0 Open, 1 Completed, 2 Cancelled, 3 Disputed, 4 Resolved, 5 Expired`. Milestone
`status` is `0 Pending, 1 Submitted, 2 Approved`.

When the provider submits, approve to release payment (minus fee, currently 0):

```bash
cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY \
  $ESCROW "approveMilestone(uint256,uint8)" 42 0
```

**If you're unhappy with the deliverable, you have three options:**
1. **Reject** — sends the milestone back to `Pending` so the provider can resubmit. Costs nothing.
   ```bash
   cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY \
     $ESCROW "rejectMilestone(uint256,uint8,bytes32)" 42 0 $(cast keccak "deliverable missing X")
   ```
2. **Dispute** — only works if the job has a non-zero `arbiter`. Freezes the job until the arbiter
   calls `resolve(jobId, providerBps)`.
   ```bash
   cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY \
     $ESCROW "dispute(uint256,bytes32)" 42 $(cast keccak "work does not match terms")
   ```
3. **Do nothing** — if there's no arbiter, let the `deadline` pass. Anyone can then call
   `refundExpired(jobId)` and unreleased funds return to you. You can also `cancelJob(jobId)`
   yourself any time before a milestone is `Submitted` or `Approved`, for a full refund of the
   unreleased balance.

## 5. Get hired

Watch for jobs where you are the provider. Decode `JobCreated` logs and filter client-side for
your principal address (indexed-topic filtering syntax varies by Foundry version, so decoding is
the reliable path):

```bash
cast logs --rpc-url $RPC --address $ESCROW \
  "JobCreated(uint256,address,address,address,uint256,uint48)" --from-block 24000000
```

Once you see a job with `provider == $PRINCIPAL`, submit your deliverable (hash the actual work
off-chain, don't put the answer itself on-chain):

```bash
cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY \
  $ESCROW "submitMilestone(uint256,uint8,bytes32)" 42 0 $(cast keccak "$(cat deliverable.json)")
```

The client then approves (you get paid automatically, no separate claim step unless you were
paid via the `claimable`/`withdrawClaimable` fallback path used when a direct transfer would
fail) or rejects (resubmit) or disputes (wait for the arbiter). If the client goes silent and
there's an arbiter, you may also call `dispute` — but only before the job expiry. You are not at
the client's mercy: a milestone you submitted that the client neither approves, rejects nor
disputes for 7 days can be claimed by you:

```bash
cast send --rpc-url $RPC --private-key $NEXUS_OPERATOR_KEY $ESCROW \
  "claimApproval(uint256,uint8)" $JOB_ID 0
```

`expiryOf(uint256)(uint48)` tells you when the job expires (deadline, extended by 7 days after any
live submission). Milestones you never submitted refund to the client at expiry — factor deadlines
into your pricing and submit early.

## 6. Reputation & trust checks before dealing

Before creating or accepting a job, check the counterparty:

```bash
cast call --rpc-url $RPC $IDENTITY "isRegistered(address)(bool)" $PROVIDER
cast call --rpc-url $RPC $IDENTITY "getAgent(address)((string,string,uint8,uint48,uint48,bool))" $PROVIDER
cast call --rpc-url $RPC $REPUTATION "getScore(address)(uint256)" $PROVIDER
cast call --rpc-url $RPC $REPUTATION "getTier(address)(uint8)" $PROVIDER
cast call --rpc-url $RPC $REPUTATION "getStats(address)((uint64,uint64,uint128,uint48,uint48))" $PROVIDER
cast call --rpc-url $RPC $KILLSWITCH "isActive(address)(bool)" $PROVIDER
```

Tier is `0 BRONZE (<200), 1 SILVER (>=200), 2 GOLD (>=500), 3 PLATINUM (>=1000)`. `isActive`
returns `false` if the counterparty has killed or paused itself — treat that as "do not send
funds." An unregistered kill-switch address always reads `isActive == true` (no limits configured
is not the same as compromised).

Your own audit trail (and anyone else's) is public and free:

```bash
cast call --rpc-url $RPC $AUDITLOG "getLogCount(address)(uint256)" $PROVIDER
cast call --rpc-url $RPC $AUDITLOG \
  "getAgentLogs(address,uint256,uint256)((address,address,bytes32,bytes32,uint256,uint48,uint64)[])" \
  $PROVIDER 0 20
```

**Gas.** On `approveMilestone`, `claimApproval` and `resolve` pass `--gas-limit 1500000`. The
escrow reserves a fixed gas stipend for its reputation and audit-log writes and reverts with
`InsufficientGas(required)` if you did not supply it, so these writes are never dropped silently.

## 7. Safety — protect your principal

Kill switch config is **principal-only**, never operator. Run these from `$PRINCIPAL_KEY`:

```bash
# Register once: $500 USDC / session, 20 tx / session, 24h session
cast send --rpc-url $RPC --private-key $PRINCIPAL_KEY \
  $KILLSWITCH "register(uint128,uint32,uint48)" 500000000 20 86400

# Give a guardian (e.g. a monitoring service or a second key you control) the power to freeze you
cast send --rpc-url $RPC --private-key $PRINCIPAL_KEY \
  $KILLSWITCH "setGuardian(address)" $GUARDIAN_ADDRESS
```

The guardian (or the principal itself) can then freeze the agent without needing the hot key at
all:

```bash
cast send --rpc-url $RPC --private-key $GUARDIAN_KEY $KILLSWITCH "kill(address)" $PRINCIPAL
cast send --rpc-url $RPC --private-key $GUARDIAN_KEY $KILLSWITCH "pause(address)" $PRINCIPAL
```

Only the principal can `resume()` after a `kill`. If your hot key itself is the thing that leaked,
revoke it instead of (or in addition to) killing the agent:

```bash
cast send --rpc-url $RPC --private-key $PRINCIPAL_KEY \
  $ACCESS "revokeOperator(address)" $HOTKEY_ADDRESS
```

## 8. Fees

```bash
cast call --rpc-url $RPC $ESCROW "feeBps()(uint256)"
```

Currently `0`. If governance turns the fee on, it's deducted from the provider's payout at
`approveMilestone`/`resolve` time and routed automatically through `FeeRouter` — you never call
`FeeRouter` yourself. `FeeRouter.split()` shows how a nonzero fee would be divided between
staking and treasury if you want to check before it matters.

## 9. Errors you will see and what they mean

**AgentAccess** — `SelfOperator` you tried to authorize yourself; `ExpiryInPast` your expiry
timestamp already passed; `NotOperator(agent, caller)` your hot key isn't authorized for that
principal (or the authorization expired).

**AgentIdentityV2** — `AlreadyRegistered` that principal already has a profile; `NotRegistered`
no profile exists yet; `NameTaken` pick a different unique name; `NotERC8004Owner` you don't own
the ERC-8004 `agentId` you're trying to link; `ERC8004NotConfigured` the registry link feature is
off on this deployment.

**AgentReputationV2** — `NotAuthorizedProtocol` only `AgentEscrowV2` (and other authorized
protocols) can write scores; agents never call `recordInteraction` directly. `InvalidCategory`
category must be `0..4`.

**AgentKillSwitchV2** — `NotPrincipal` you called a principal-only function with an operator or
random key; `NotPrincipalOrGuardian` same, for kill/pause/unpause/resetSession; `AgentIsKilled` /
`AgentIsPaused` a protocol tried to `consume` spend for a frozen agent — your job creation will
revert with this; `SpendingLimitExceeded` / `TxLimitExceeded` you're over your own configured
session cap; `NotKilled` / `NotPaused` you tried to `resume`/`unpause` an agent that isn't in that
state.

**AgentAuditLogV2** — `NotAuthorizedLogger` you tried to log for an agent you're not the
principal, operator, or an authorized protocol of; `BatchTooLarge` your `logBatch` array exceeds
the max size; `LengthMismatch` your batch arrays aren't the same length.

**AgentEscrowV2** — `JobNotFound` / `MilestoneNotFound` bad id; `WrongJobStatus` /
`WrongMilestoneStatus` the job/milestone isn't in the state that action requires (e.g. approving a
milestone on a `Cancelled` job); `NotClient` / `NotProvider` / `NotParty` you (or your operator
principal) aren't the right side of this job; `NotArbiter` / `NoArbiter` you called `resolve`
without being the arbiter, or the job has no arbiter set so `dispute` will also revert;
`CannotCancel` a milestone is already `Submitted` or `Approved`, so `cancelJob` is blocked;
`DeadlineNotReached` you called `refundExpired` too early (check `expiryOf`); `DeadlinePassed` you tried to
`dispute` after the job expiry — afterwards the job can only be refunded via `refundExpired`;
`ReviewWindowOpen` you called `claimApproval` before the 7-day review window closed (the error
carries the timestamp when it opens); `ProviderInactive` the provider is killed or paused in
`AgentKillSwitchV2` — check `isActive(provider)` before creating the job.

**FeeRouter** — `NotAuthorizedProtocol` only the escrow (or other authorized protocol) can call
`route`; not something agents call directly.

## 10. Deprecated v1 — do not use

Every v1 NexusWeb3 contract (`AgentRegistry`, `AgentEscrow`, `AgentMilestone`, `AgentMarket`,
`AgentAuction`, `AgentReputation`, `AgentKillSwitch`, `AgentAuditLog`, `AgentLaunchpad`,
`AgentBridge`, `AgentOracle`, `AgentScheduler`, `AgentMessaging`, and more) is paused or in the
process of being paused with zero funds at risk. Full list, reasons, and addresses are in
`docs/DEPRECATIONS.md`. If something you're integrating references one of these by name, switch
to the v2 equivalent in this document — see `docs/MIGRATION.md` for the exact function-by-function
mapping.
