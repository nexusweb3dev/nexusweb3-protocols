# Changelog

## 2.1.0 — 2026-09-22 (security hardening)

### Follow-up (same release)
- `AgentAccess.operatorExpiry` returns 0 once an authorization lapsed (monitors and the arbiter-independence check see live operators only).
- `AgentIdentityV2.rename(agent, newName)` — take a new name and release the old one; works on deactivated profiles.
- `AgentEscrowV2` emits `PayoutSettled(jobId, account, amount, delivered)` on every payout attempt, so indexers can tell delivered from parked funds without joining `ClaimableAdded`.
- SDKs: `identity.rename`, `payouts` decoded from receipts, sanitized error output, vitest upgraded (0 advisories). CI actions pinned to commit SHAs.

### AgentEscrowV2 / EscrowBase (`src/v2/`)
- **Offer/accept lifecycle** — `createJob` now creates an offer only; the provider must call the
  new `acceptJob(jobId)` before submit, approve, reject, dispute, or reputation apply. Before
  acceptance the client may `cancelJob` at any time for a full refund and no reputation is
  recorded for either side. New errors `NotAccepted`, `AlreadyAccepted`.
- **`refundExpired` renamed to `settleExpired(jobId)`** and given a real rule: `Submitted`
  milestones vest to the provider (paid minus fee), `Pending` milestones refund the client. `Open`
  jobs settle after `expiryOf` (`max(deadline, last submission + REVIEW_WINDOW)`); `Disputed` jobs
  settle `DISPUTE_GRACE` (30 days) after `disputedAt` if the arbiter stays silent — same
  provider-favoring rule for submitted work. Client/arbiter silence is now a property of job state,
  not a race either side can win by default.
- **`cancelJob`** narrowed post-acceptance: allowed only while no milestone has ever been
  submitted (`job.everSubmitted`); new error path replaces the old "not Submitted/Approved" check.
- **`submitMilestone`** capped at `MAX_REJECTIONS` (3) resubmissions per milestone; beyond that the
  milestone stays `Pending` and can only be refunded at settlement. New error `TooManyRejections`.
- **`rejectMilestone`** now reverts with the new error `ReviewWindowClosed` once the 7-day
  `REVIEW_WINDOW` has passed — the milestone is already vested to the provider by then.
- **`withdrawClaimable(address account, address to)`** — signature changed from a self-only
  withdrawal to an explicit recipient, callable by `account` or its `AgentAccess` operator.
- **Arbiter independence** — `createJob` now reverts `InvalidParty` if the arbiter is an operator
  of either party, or either party is an operator of the arbiter (checked via `AgentAccess`, using
  `operatorExpiry`; see the `AgentAccess` note below on why that check is stricter than a live
  `isOperatorFor` lookup).
- **Reputation** — a `resolve` split of exactly 50/50 is now neutral (no reputation event either
  way); recorded volume is each side's actual settled share; new
  `MIN_REPUTATION_VALUE` (10 USDC, `10_000_000` in 6-decimal units) gates every reputation event,
  positive or negative, by the settled (or, for `resolve`, disputed) amount, so a dust-sized job or
  dispute can neither farm nor grief a score; new `MAX_REPUTATION_PER_PAIR` (10) caps recorded
  events per client/provider pair to bound wash-trading, and that budget is only spent when an
  event actually clears the `MIN_REPUTATION_VALUE` floor.
- **Gas floors** — every fund-moving path (`approveMilestone`, `claimApproval`, `settleExpired`,
  `resolve`) now requires ~1.2M gas available for its reputation/audit/fee hooks; state-only paths
  (`createJob`, `cancelJob`, `dispute`, `rejectMilestone`, `submitMilestone`) need ~700k. New error
  `InsufficientGas(required)` replaces silent hook drops.
- **Token safety** — `createJob`/`createJobWithPermit` now revert `TokenAmountMismatch` if the
  received balance is less than the requested total (fee-on-transfer guard); deployment remains
  USDC-only. The constructor also now reverts `ZeroAddress` if `paymentToken` has no code,
  catching a misconfigured or non-contract token address at deploy time.

### AgentAccess (`src/v2/`)
- **`renounceOperator(agent)`** — a new self-service function letting an operator drop its own
  authorization immediately (no principal key needed), for the case where an automated process
  suspects its own hot key is compromised. Emits `OperatorRenounced`.
- **`operatorExpiry` can be stale** — it is a raw storage read and may return a non-zero but
  already-expired timestamp; `isOperatorFor` is the authoritative, current-validity check. Note
  this also means `AgentEscrowV2`'s arbiter-independence check (which reads `operatorExpiry`
  directly) treats a since-expired-but-never-revoked operator link as still disqualifying — an
  explicit `revokeOperator` (or `renounceOperator`) is needed to fully clear it for arbiter
  selection.

### AgentKillSwitchV2 (`src/v2/`)
- **`resetSession`** is now strictly principal-only; the guardian role is restricted to
  kill/pause/unpause and can never restore spending headroom.
- **`remainingSpend`** returns `0` instead of reverting when a previously lowered `spendingLimit`
  is already below the amount spent this session.

### AgentIdentityV2 (`src/v2/`)
- **`linkERC8004`** reverts the new error `InvalidERC8004Id` for `agentId == 0`.
- Links now correctly read as absent (`erc8004IdOf`/`agentOfERC8004` return `0`/`address(0)`) after
  `setERC8004Registry` bumps `registryEpoch`; affected agents must re-link.
- **Name charset** — `register` now restricts names to `[a-z0-9-_.]`; anything else reverts the
  new error `InvalidName`.

### FeeRouter (`src/v2/`)
- **`route`** emits the new event `ReferralCallFailed(agent, amount)` when the v1 `AgentReferral`
  sink reverts, and continues distributing the remainder to staking/treasury instead of blocking
  the caller's payout.

### Ownership
- All six owned v2 contracts (`AgentIdentityV2`, `AgentReputationV2`, `AgentAuditLogV2`,
  `AgentKillSwitchV2`, `AgentEscrowV2`, `FeeRouter`) confirmed `Ownable2Step`; deploy runbook
  updated with the `acceptOwnership()` handoff and a multisig recommendation for mainnet.

### Docs
- `docs/MIGRATION.md`, `integrations/openclaw-skill-v2.md`, `README.md`, and
  `deployments/V2-RUNBOOK.md` updated for the above: new lifecycle, renamed/added functions, full
  error list, and updated gas guidance.

### Tests
- See `test/v2/` for updated unit/integration coverage, `test/v2/invariants/` for the new Foundry
  invariant suite, and `test/v2/symbolic/` for Halmos proofs. Security audit in progress:
  `reviews/v2/V2-SECURITY-AUDIT.md`.

## 2.0.0 — 2026-09-21 (branch `v2/core-stack`, deploy pending)

### Contracts (`src/v2/`)
- **AgentAccess** — principal → operator delegation with expiry; read by every v2 contract.
- **AgentIdentityV2** — free, permanent identity; ERC-8004 agentId link with ownership check and stale-link clearing.
- **AgentEscrowV2** — milestone escrow; party-chosen arbiter; EIP-2612 permit funding; 7-day review window with provider `claimApproval`; expiry = max(deadline, last submission + 7d); claimable fallback for blocked recipients; gas-floored best-effort hooks (`InsufficientGas`); atomic best-effort fee routing.
- **AgentReputationV2** — value-weighted score written by authorized protocols; all reads free.
- **AgentAuditLogV2** — free, paginated per-agent action log; protocols log on agents' behalf.
- **AgentKillSwitchV2** — opt-in spend/tx limits enforced via `consume`; guardian; auto-rolling sessions; principal can resume.
- **FeeRouter** — referral → staking → treasury split; fee switch default 0.

### Tooling
- `script/v2/DeployCore.s.sol` deploys and wires all authorizations, writes `deployments/v2-<chainId>.json`; `DeployLocal.s.sol` for anvil with a permit-capable mock USDC.
- `sdk/ts` — TypeScript SDK (viem) + MCP server with 13 tools. `sdk/python` — Python SDK + CLI.
- `integrations/openclaw-skill-v2.md` — agent skill with runnable `cast` flows.
- CI: `forge fmt --check` on v2, SDK unit + end-to-end jobs on anvil.

### Deprecations
23 v1 contracts deprecated (zero usage, zero funds). Reasons and replacements: `docs/DEPRECATIONS.md`. Migration: `docs/MIGRATION.md`.

### Tests
1562 Foundry tests (1138 v1 + 424 v2). Slither on `src/v2`: no actionable findings. Adversarial review closed.

## 1.2.0 — unreleased (branch `fix/insolvency-late-confirm-drain`)
- AgentInsolvency: freeze `confirmDebt` after insolvency; cap payouts per agent (issue #2).

## 1.1.0 / 1.0.x — March 2026
- Initial 30-protocol deployment on Base mainnet and security fix redeploys. See `deployments/DEPLOYMENTS.md`.
