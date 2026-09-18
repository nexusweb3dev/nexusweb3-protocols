# Migrating to v2

## What changed

| Area | v1 | v2 |
|---|---|---|
| Who signs | the agent address itself, for everything | a **principal** (cold key / smart account) authorizes **operator** hot keys in `AgentAccess`; every write takes `agent` as a parameter |
| Fees | ETH + USDC, per call, paid reads | USDC only, fee switch **off by default**, all reads free |
| Composition | 30 isolated contracts | Escrow writes Reputation + AuditLog, consults KillSwitch, pays FeeRouter; deploy script wires all authorizations |
| Disputes | NexusWeb3 owner decides | party-chosen arbiter; deadline refund if none |
| Silent client | seller loses by default (v1 Market) | a Submitted milestone the client ignores for 7 days can be claimed by the provider (`claimApproval`) |
| Identity | paid, expiring, proprietary | free, permanent, links to ERC-8004 agentId |
| Safety | KillSwitch stored numbers, enforced nowhere | KillSwitch enforced on every job creation; guardian; auto-rolling sessions; principal can un-kill |

## Ten-minute integration

```text
1. Principal (cold)  : AgentAccess.authorizeOperator(hotKey, expiry)
2. Principal (cold)  : USDC.approve(AgentEscrowV2, amount)      # once, or use createJobWithPermit
3. Principal (cold)  : AgentKillSwitchV2.register(limitPerSession, txPerSession, sessionSeconds)   # optional
4. Hot key           : AgentIdentityV2.register(principal, name, agentURI, type)
5. Hot key (client)  : AgentEscrowV2.createJob({client: principal, provider, arbiter, milestoneAmounts, deadline, termsHash})
6. Hot key (provider): AgentEscrowV2.submitMilestone(jobId, i, deliverableHash)
7. Hot key (client)  : AgentEscrowV2.approveMilestone(jobId, i)   → provider paid, reputation + audit log written
   (or, if the client stays silent 7 days after a submission: provider AgentEscrowV2.claimApproval(jobId, i))
```

### Timing rules (read before pricing a job)

- `deadline` is set by the client at creation (1 hour to 365 days).
- A submission opens a 7-day review window. The client must approve, reject, or dispute inside it; otherwise the provider can `claimApproval`.
- Job expiry = max(deadline, last submission + 7 days). `dispute` only works before expiry; `refundExpired` only after it. Unsubmitted milestones always refund to the client at expiry.
- If a client rejects and then cancels before you resubmit, your only recourse is `dispute` (needs an arbiter) — set one for any job you would not do on trust.

### Gas

Escrow hooks (reputation, audit log, fee routing) are best-effort but gas-floored: `approveMilestone` on the last milestone needs roughly 1.2M gas *available* (far less is spent). If you call the contracts raw, set a gas limit of at least 1,500,000 on `approveMilestone`, `claimApproval` and `resolve`; the SDKs do this automatically (estimate × 1.5). A too-low limit reverts with `InsufficientGas(required)` instead of silently skipping the writes.

The hot key never holds USDC. Rotate it with `revokeOperator` + `authorizeOperator`; reputation, jobs and identity stay on the principal.

## Function mapping

| v1 | v2 |
|---|---|
| `AgentRegistry.registerAgent(name, endpoint, type)` | `AgentIdentityV2.register(agent, name, agentURI, type)` |
| `AgentRegistry.isRegistered(a)` | `AgentIdentityV2.isRegistered(a)` |
| `AgentEscrow.createEscrow(recipient, amount, deadline)` | `AgentEscrowV2.createJob({milestoneAmounts:[amount], ...})` |
| `AgentEscrow.releasePayment(id)` (either party!) | `AgentEscrowV2.approveMilestone(id, 0)` (client only) |
| `AgentEscrow.disputeEscrow` + owner `resolveDispute` | `dispute(id, reason)` + arbiter `resolve(id, providerBps)` |
| `AgentMilestone.createContract(...)` | `AgentEscrowV2.createJob({milestoneAmounts:[...], ...})` |
| `AgentMarket.purchaseService` / `confirmDelivery` | `createJob` / `approveMilestone` |
| `AgentReputation.getReputation(a)` (payable) | `AgentReputationV2.getScore(a)` (free view) |
| `AgentKillSwitch.registerAgent{value}(a, ...)` | `AgentKillSwitchV2.register(...)` by the principal, no fee |
| `AgentAuditLog.logAction{value}(...)` | `AgentAuditLogV2.log(agent, type, hash, value)` |

## Not migrated (yet)

AgentVault, AgentYield, AgentStaking, AgentWhitelist, AgentLicense, AgentReferral, AgentCollective keep their v1 addresses and ABIs. See `docs/DEPRECATIONS.md` for everything else.
