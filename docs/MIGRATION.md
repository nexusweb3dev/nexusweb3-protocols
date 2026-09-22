# Migrating to v2

## What changed

| Area | v1 | v2 |
|---|---|---|
| Who signs | the agent address itself, for everything | a **principal** (cold key / smart account) authorizes **operator** hot keys in `AgentAccess`; every write takes `agent` as a parameter |
| Fees | ETH + USDC, per call, paid reads | USDC only, fee switch **off by default**, all reads free |
| Composition | 30 isolated contracts | Escrow writes Reputation + AuditLog, consults KillSwitch, pays FeeRouter; deploy script wires all authorizations |
| Disputes | NexusWeb3 owner decides | party-chosen, on-chain-verified independent arbiter; expiry settlement if none |
| Silent client | seller loses by default (v1 Market) | a Submitted milestone the client ignores for 7 days vests to the provider (`claimApproval`, or automatically at `settleExpired`) — this is a property of job state, not a race a silent client can win |
| Identity | paid, expiring, proprietary | free, permanent, links to ERC-8004 agentId |
| Safety | KillSwitch stored numbers, enforced nowhere | KillSwitch enforced on every job creation; guardian; auto-rolling sessions; principal can un-kill |

Jobs are now **offers**: `createJob` locks the client's funds but the provider isn't bound to anything until it calls `acceptJob(jobId)`. Before acceptance there is no submit, approve, or dispute, and no reputation is recorded for either side — the client can `cancelJob` at any time for a full refund. After acceptance, `cancelJob` still works, but only for as long as no milestone has ever been submitted.

## Operator key blast radius (read before setting an allowance)

The principal/operator model is safer than v1's "the agent key is everything," but a compromised operator key is still not harmless. A leaked client operator key can, in the same session: `createJob` naming an attacker-controlled address as `provider` for the full standing USDC allowance, wait for that attacker address to self-`acceptJob` (instant — it's the attacker's own key), then call `approveMilestone` to release the funds — all inside a single block if the attacker is ready. Nothing about the offer/accept split or the review window protects you here, because the compromised key is acting as *you*, the client.

What actually bounds the damage:

- **A registered kill switch caps it.** `AgentKillSwitchV2.register(spendingLimit, txLimit, sessionDuration)` makes `createJob` revert once the session's `spendingLimit` is spent, regardless of your token allowance. Without one, a leaked operator key can spend the entire `USDC.approve` allowance in one shot.
- **`createJobWithPermit` avoids a standing allowance entirely.** Each job is funded by a fresh EIP-2612 signature from the cold principal key for that job's exact amount, so a leaked hot key alone can't create a job at all — it still needs a per-job signature it doesn't have. This is the strongest mitigation and costs no extra on-chain step.
- **If you do use `USDC.approve`, size it to one job**, not a large standing balance, and re-approve per job (or per small batch) instead of approving a large amount once.
- **`AgentAccess.renounceOperator(agent)`** lets the operator key itself drop its own authorization the instant it suspects compromise, without needing the principal's cold key online. Wire your agent process to call this defensively on any anomaly it detects in itself.

Recommended defaults for any integration: register a kill switch, prefer `createJobWithPermit` per job over a standing `approve`, and if an allowance is unavoidable, keep it at one job's size.

## Ten-minute integration

```text
1. Principal (cold)   : AgentAccess.authorizeOperator(hotKey, expiry)
2. Principal (cold)   : USDC.approve(AgentEscrowV2, amount)      # once, or use createJobWithPermit
3. Principal (cold)   : AgentKillSwitchV2.register(limitPerSession, txPerSession, sessionSeconds)   # optional
4. Hot key            : AgentIdentityV2.register(principal, name, agentURI, type)
5. Hot key (client)   : AgentEscrowV2.createJob({client: principal, provider, arbiter, milestoneAmounts, deadline, termsHash})   → offer, provider not yet bound
6. Hot key (provider) : AgentEscrowV2.acceptJob(jobId)            → job is live; disputes/reputation now apply
7. Hot key (provider) : AgentEscrowV2.submitMilestone(jobId, i, deliverableHash)
8. Hot key (client)   : AgentEscrowV2.approveMilestone(jobId, i)   → provider paid, reputation + audit log written
   (or, if the client stays silent 7 days after a submission: provider AgentEscrowV2.claimApproval(jobId, i))
```

### Timing rules (read before pricing a job)

- `deadline` is set by the client at creation (1 hour to 365 days). A provider that never calls `acceptJob` before the deadline can no longer accept.
- `submitMilestone` only works up to the deadline, and only up to `MAX_REJECTIONS` (3) rejections per milestone; past that the milestone stays `Pending` forever and can only be refunded to the client when the job settles.
- A submission opens a 7-day review window (`REVIEW_WINDOW`). The client can `rejectMilestone` only inside it; past the window the milestone is already vested to the provider (client can still `approveMilestone`, or the provider can `claimApproval`).
- Job expiry = max(deadline, last Submitted milestone's `submittedAt` + 7 days). `dispute` only works before expiry; `settleExpired` (formerly `refundExpired`) only after it. On expiry, every `Submitted` milestone pays the provider (minus fee) and every `Pending` milestone refunds the client — never the other way around.
- A `Disputed` job that the arbiter never resolves settles the same way, 30 days after the dispute (`DISPUTE_GRACE`): submitted work still pays the provider. A silent arbiter no longer defaults in the client's favor.
- If a client rejects and then cancels before you resubmit — it can't: once any milestone has ever been submitted, `cancelJob` is blocked (`CannotCancel`). Your only recourse from there is `dispute` (needs an arbiter) or waiting for `settleExpired`.
- The arbiter must be independent: at job creation the contract checks via `AgentAccess.operatorExpiry` that the arbiter is not an operator of either party and neither party is an operator of the arbiter. This is an on-chain guarantee at creation time only — it cannot detect an arbiter address that the client controls off-chain through an unrelated principal, so providers should still vet who they agree to. Note also that this check reads the raw `operatorExpiry` record, not the live `isOperatorFor` status: an operator relationship that has since **expired** but was never explicitly `revokeOperator`-ed still disqualifies that address as an arbiter (the stale timestamp is still non-zero). `isOperatorFor` is always the right call for "is this currently authorized"; `operatorExpiry` is a raw storage read that can be non-zero and stale.
- Reputation — positive *or* negative — is only recorded when the settled or disputed amount is at or above `MIN_REPUTATION_VALUE` (10 USDC); for `resolve`, the gate is the disputed amount, not either side's split. Below that floor a job still pays out normally, it just moves nothing on anyone's score — a dust job can neither farm a positive nor grief a negative. The `MAX_REPUTATION_PER_PAIR` (10) budget is likewise only spent when an event actually clears the floor; a dust job never touches it.

### Gas

Escrow hooks (reputation, audit log, fee routing) are best-effort but gas-floored. Fund-moving functions need roughly 1.2M gas *available*: `approveMilestone`, `claimApproval`, `settleExpired`, `resolve`. Non-fund-moving state changes need roughly 700k: `createJob`, `cancelJob`, `dispute`, `rejectMilestone`, `submitMilestone`. If you call the contracts raw, set `--gas-limit 1500000`; the SDKs do this automatically (estimate × 1.5). A too-low limit reverts with `InsufficientGas(required)` instead of silently skipping the writes.

The hot key never holds USDC. Rotate it with `revokeOperator` + `authorizeOperator` (principal-driven), or have the hot key drop itself with `renounceOperator` (operator-driven, no principal key needed) the moment it suspects it's been compromised. Reputation, jobs and identity stay on the principal.

## Function mapping

| v1 | v2 |
|---|---|
| `AgentRegistry.registerAgent(name, endpoint, type)` | `AgentIdentityV2.register(agent, name, agentURI, type)` — `name` is now restricted to `[a-z0-9-_.]` (`InvalidName` otherwise) |
| `AgentRegistry.isRegistered(a)` | `AgentIdentityV2.isRegistered(a)` |
| `AgentEscrow.createEscrow(recipient, amount, deadline)` | `AgentEscrowV2.createJob({milestoneAmounts:[amount], ...})` + provider `acceptJob(id)` |
| `AgentEscrow.releasePayment(id)` (either party!) | `AgentEscrowV2.approveMilestone(id, 0)` (client only, after `acceptJob`) |
| `AgentEscrow.disputeEscrow` + owner `resolveDispute` | `dispute(id, reason)` + independent arbiter `resolve(id, providerBps)` |
| `AgentMilestone.createContract(...)` | `AgentEscrowV2.createJob({milestoneAmounts:[...], ...})` + `acceptJob` |
| `AgentMarket.purchaseService` / `confirmDelivery` | `createJob` + `acceptJob` / `approveMilestone` |
| n/a (new in v2) | `AgentEscrowV2.acceptJob(id)` — provider binds itself to the offer before submit/dispute/reputation apply |
| n/a (new in v2) | `AgentEscrowV2.settleExpired(id)` — replaces `refundExpired`; vests Submitted work to the provider, refunds Pending work to the client |
| n/a (new in v2) | `AgentEscrowV2.withdrawClaimable(account, to)` — pulls parked funds (failed transfer, e.g. blacklisted recipient) to any address you choose |
| n/a (new in v2) | `AgentAccess.renounceOperator(agent)` — an operator drops its own authorization immediately, no principal key needed |
| `AgentReputation.getReputation(a)` (payable) | `AgentReputationV2.getScore(a)` (free view) |
| `AgentKillSwitch.registerAgent{value}(a, ...)` | `AgentKillSwitchV2.register(...)` by the principal, no fee |
| `AgentAuditLog.logAction{value}(...)` | `AgentAuditLogV2.log(agent, type, hash, value)` |

## Not migrated (yet)

AgentVault, AgentYield, AgentStaking, AgentWhitelist, AgentLicense, AgentReferral, AgentCollective keep their v1 addresses and ABIs. See `docs/DEPRECATIONS.md` for everything else.
