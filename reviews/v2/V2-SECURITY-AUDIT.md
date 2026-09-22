# NexusWeb3 v2 Core — Pre-Deployment Security Audit

**Date:** 2026-09-22 · **Commit under audit:** `main` @ `81684aa` (PR #3) → fixes on branch `security/v2-audit`
**Scope:** `src/v2/*.sol` (9 contracts, 1,771 lines after fixes), `src/v2/interfaces/*.sol`, `script/v2/*.s.sol`, `sdk/ts`, `sdk/python`, `.github/workflows/sdk.yml`
**Out of scope:** v1 contracts (deprecated, zero usage), OpenZeppelin 5.1.0, Base USDC itself.

## 1. Method

| Layer | Tool / approach | Result |
|---|---|---|
| Static analysis | Slither 101 detectors, all severities (`reviews/v2/slither-full.txt`, post-fix `slither-full-post.txt`) | 39 → 40 results (one added event), 0 exploitable — triage in §4 |
| Static analysis | Aderyn (`reviews/v2/aderyn.md`) | 1 High class (reentrancy pattern, see §4), 11 Low/Info |
| Line coverage | `forge coverage` on v2 tests | before: 99.7% lines / 96.6% branches; after fixes + new suites: 100% lines and functions on every v2 contract (876/877 lines) |
| Unit + fuzz | 721 v2 test functions (unit, fuzz at 1000 runs, 87 audit regressions); every function, every revert, both principal and operator paths | pass |
| Cross-contract | `test/v2/Integration.t.sol` full lifecycle with real modules, fee switch on | pass |
| Stateful invariants | `test/v2/invariants/` — random actors drive every escrow entrypoint (incl. accept/settle) plus kill-switch and owner operations across time; ghost accounting; a deterministic drive proves every terminal state is reachable | 5 invariants × 2,000 runs × 150 depth = 300,000 calls each on the final code, 0 violations |
| Symbolic execution | Halmos 0.3.3 on `test/v2/symbolic/Symbolic.t.sol` | fee-split conservation, kill-switch bounds, reputation formula proven for all inputs (reputation to loop bound 8) |
| Manual review | 5 independent auditors, line by line: escrow money paths; access/kill-switch/fee-router; identity/reputation/audit-log/deploy; economic & token edge cases; SDK + MCP threat model | findings in §3 |
| Gas-floor property | `test_gasFloor_noLimitDropsHooksSilently` sweeps gas limits 60k–1.4M | no limit exists where a call succeeds but a hook write is dropped |

Invariants checked (all hold):
1. **Solvency** — `USDC.balanceOf(escrow) == Σ(total − released − refunded) + Σ claimable`.
2. **Conservation** — every USDC deposited is either still held or was paid out.
3. **Job accounting** — `released + refunded ≤ total`; live jobs have `released == Σ approved`; terminal jobs are fully settled; Completed ⇒ all milestones approved and nothing refunded; Cancelled ⇒ nothing released.
4. **Kill-switch bounds** — `spent ≤ spendingLimit`, `txCount ≤ txLimit` within a session.
5. **Reputation bounded by work** — positives never exceed `2 × approvals + resolutions + expiries`.

## 2. Trust model (what the audit assumes)

- **Principal** (cold key / smart account) holds USDC and identity; it is the only party that can change kill-switch limits. Compromise of the principal = loss of its funds, as with any wallet.
- **Operator** (hot key) can do everything else for the principal, including creating jobs that spend the principal's USDC allowance. Blast radius of a compromised operator = kill-switch limit if registered, else the full escrow allowance. This is the documented trade-off; mitigations in §3.
- **Arbiter** is chosen by the client at job creation; the provider must vet it before submitting work.
- **Owner** is honest but fallible: it can misconfigure modules or fees. The contracts are designed so an owner mistake parks fees or skips reputation writes, never locks user funds.
- **Payment token** is Base USDC: 6 decimals, EIP-2612 (version "2"), blacklist, returns `bool`, no fee-on-transfer.

## 3. Findings

Severity is the auditor's assessment of impact on the pre-fix code. Every finding has a regression test in `test/v2/audit/` (id in the test name) and is fixed on branch `security/v2-audit` unless marked *Accepted*.

### High

| ID | Contract | Finding | Fix |
|---|---|---|---|
| F-1 / E-01 | AgentEscrowV2 | `claimApproval` and `refundExpired` unlocked in the same second, so a client (or searcher) could front-run the provider's claim and refund a milestone the client had silently accepted. | Vesting: `settleExpired` pays every Submitted milestone to the provider and refunds only Pending ones. Whoever settles, the outcome is the same. `refundExpired` removed. |
| F-2 | AgentEscrowV2 | Disputed-branch grace measured from `deadline` while Open-branch expiry could be later; disputing could make a job refundable *earlier* and lock the arbiter out. | Grace runs from `disputedAt` (stored on dispute). |
| E-06 | AgentEscrowV2 | Dispute + silent client-chosen arbiter returned 100% to the client, including submitted work. | Grace settlement uses the same vesting rule: submitted work pays the provider. |
| E-04 | AgentEscrowV2 | Anyone could create a dust job naming a victim as provider, dispute, and resolve at 0 bps to give the victim a negative reputation without the victim ever signing. | Jobs are offers until `acceptJob`; no submit/approve/dispute and no reputation before acceptance. |
| H-01 | AgentIdentityV2 | ERC-8004 agentId 0 (a real token on the Base registry) was both linkable and the "unlinked" sentinel, corrupting other agents' links. | `InvalidERC8004Id` for id 0. |
| H-02 | DeployCore | Single-step `transferOwnership` to a mistyped OWNER would permanently brick admin on six contracts. | All six contracts are `Ownable2Step`; runbook adds `acceptOwnership`. |

### Medium

| ID | Contract | Finding | Fix |
|---|---|---|---|
| E-02 / F-3 | AgentEscrowV2 | Provider could chain submissions (each re-arming a 7-day window) to lock client funds indefinitely; a long-expired job could be "resurrected" by a late submission. | `submitMilestone` reverts after the deadline; `MAX_REJECTIONS = 3` per milestone. Expiry is bounded by `deadline + 7d`. |
| E-03 | AgentEscrowV2 | Client could reject and cancel in one block, leaving a provider with delivered work no recourse. | `cancelJob` reverts once any milestone was ever submitted. |
| F-4 | AgentEscrowV2 | A blacklisted recipient could never withdraw its parked balance (fallback re-ran the failing transfer). | `withdrawClaimable(account, to)`; callable by account or operator, pays any address. |
| F-5 | AgentEscrowV2 | Nothing stopped a client seating its own operator as arbiter. | On-chain independence check via `AgentAccess.operatorExpiry` in both directions; explicit provider acceptance. |
| E-09 | AgentEscrowV2 | A fee-on-transfer token (misdeploy) would record `total` but receive less, stranding parked funds. | Balance-delta check → `TokenAmountMismatch`. |
| M-03 | AgentReputationV2 | Reputation cheap to buy: two principals controlled by one party can wash-trade at gas cost while fees are 0. | `MAX_REPUTATION_PER_PAIR = 10` events per client/provider pair; even splits neutral; volume = actual settled share. *Partially accepted*: Sybil across many principals still costs only gas; documented, fee switch and arbiter requirements are the economic lever. |
| KS-2 | AgentKillSwitchV2 | Guardian could `resetSession` repeatedly and refill the spending cap; a principal naming its hot key as guardian would let the hot key widen limits. | `resetSession` is principal-only. |
| FR-2 / M-02 | FeeRouter / DeployCore | Referral call failure (router not authorized on v1 AgentReferral, which the deploy script never did) was swallowed silently; referrers earned nothing, indistinguishable from "no referrer". | `ReferralCallFailed` event; deploy script attempts the authorization and warns loudly; runbook step. |
| M-01 | DeployLocal | No chain guard; could run against any RPC and hand out a mock USDC. | `require(block.chainid == 31337)`. |
| M-04 | AgentIdentityV2 | Changing the ERC-8004 registry left links validated against the old registry readable. | Registry epoch; links from an old epoch read as unlinked. |
| M-05 | AgentAuditLogV2 | `getAgentLogs` had no page cap (≈5M gas per 1,000 entries). | `MAX_PAGE_SIZE = 200`. |

### Low

| ID | Contract | Finding | Fix |
|---|---|---|---|
| F-6 | AgentEscrowV2 | `submitMilestone`, `rejectMilestone`, `dispute` lacked `nonReentrant`; a malicious module that is also an operator could flip a job to Disputed mid-approve (accounting survived thanks to CEI). | `nonReentrant` on every state-changing entrypoint. |
| F-7 | AgentEscrowV2 | `provider == address(escrow)` self-paid and broke the balance identity. | Parties may not be the escrow. |
| F-10 | AgentEscrowV2 | `resolve(5000)` penalised the client. | Even split is reputation-neutral. |
| KS-1 | AgentKillSwitchV2 | Lowering the limit below `spent` made `remainingSpend` panic and `consume` revert with a Panic instead of the custom error. | Clamped. |
| KS-4 | AgentKillSwitchV2 | Any authorized protocol can burn any agent's session budget (no funds move). | *Accepted*: inherent; keep the authorized set to Escrow only. |
| FR-1 | FeeRouter | Referral sink held an unlimited allowance; a malicious referral could pull the router's whole balance. | Allowance set to exactly `amount` before the call and zeroed after. |
| F-8 | AgentEscrowV2 | Gas floors undocumented for `refundExpired`/`cancelJob`/`createJob`. | Documented in MIGRATION.md and the skill. |
| E-05 | AgentReputationV2 / Escrow | Dust jobs (0.000001 USDC milestones) could farm PLATINUM for gas alone. | `MIN_REPUTATION_VALUE = $10`: positive reputation only for settled amounts ≥ $10, plus the per-pair cap. |
| ACC-3 | AgentAccess | An operator could not resign its own key after a suspected leak. | `renounceOperator(agent)`. |
| L-01 | AgentIdentityV2 | Names accepted homoglyphs, case variants, whitespace and control bytes, enabling impersonation. | Names restricted to `[a-z0-9-_.]` (`InvalidName`). |
| L-05 / L-06 | DeployCore | Silent bps truncation; no post-wiring assertions. | Range checks; `_wire` asserts every `isAuthorizedProtocol` and module address on-chain. |
| E-09b | EscrowBase | Constructor accepted a token address without code (`_payOut` treats empty return data as success). | Constructor requires `code.length > 0`. |
| SDK-1 | sdk/ts MCP | `nexus_access_authorize_operator` was always registered; a prompt-injected model holding the principal key could delegate to an attacker. | Gated behind `NEXUS_MCP_ALLOW_PRINCIPAL_WRITES=1` (default off). |
| SDK-2 | sdk/ts | Chain id from the deployment JSON was read but never verified against the RPC. | MCP refuses to start on mismatch. |
| SDK-3 | sdk/ts MCP | `nexus_escrow_create_job` had no spend cap. | `NEXUS_MCP_MAX_JOB_AMOUNT`; gas multiplier bounded at 5×. |
| SDK-4 | sdk/python | Permit domain version defaulted to "1"; Base USDC signs "2", failing silently into a confusing allowance error. | EIP-5267 detection with known-address fallback. |
| SDK-5 | both SDKs | Amount units differed between CLI (USDC) and MCP (base units). | All surfaces take human USDC strings. |

### Informational / Accepted

| ID | Note |
|---|---|
| F-9 | `MilestoneApproved`/`JobResolved`/`JobExpired` report gross amounts even when a transfer was parked; indexers must join `ClaimableAdded`. Documented. |
| E-10 | Operator-key compromise blast radius = kill-switch limit, or the full escrow allowance without one. SDKs default to registering a kill switch; documented in the trust model. |
| E-07 | With no arbiter, a client can reject up to 3 times per milestone at gas cost; funds return to the client at the deadline. Providers should require an arbiter for work they would not do on trust. |
| — | `isOperatorFor(address(0), address(0))` is true; no caller uses address(0) as a sentinel principal. |
| E-12 | Compromised client operator can drain the standing allowance up to the kill-switch session limit. Mitigations documented: kill switch by default, per-job `createJobWithPermit`, one-job allowances. |
| KS-3 | A guardian kill is reversible by the principal without timelock. By design: the principal is the owner of the funds. |
| L-02 | A deactivated identity's name is reserved to that principal forever; there is no admin override. By design (no owner power over identities). |
| L-04 | Authorized protocols write audit-log entries for any agent. By design; the authorized set is Escrow only. |
| ACC-2 | `operatorExpiry` may return an expired timestamp; `isOperatorFor` is the authoritative check. Documented. |
| deps | npm production: 0 vulnerabilities; npm dev: 2 moderate (vitest mocker, dev-only); pip-audit on shipped deps: 0. |


## 4. Static-analysis triage

| Detector | Location | Verdict |
|---|---|---|
| arbitrary-send-erc20 | `AgentEscrowV2._create` `safeTransferFrom(p.client, …)` | By design: `_requireAgentOrOperator(p.client)` runs first; only the principal or its operator can pull the principal's USDC. PoC: `test_revert_createJob_strangerCannotSpendPrincipal`. |
| reentrancy-no-eth / reentrancy-events / reentrancy-benign | `_approve`, `resolve`, `cancelJob`, `refundExpired` | All entrypoints that move funds are `nonReentrant`; state (status, released, refunded, approvedCount) is updated before external calls; the only post-call write is `_claimable += amount` inside the transfer-failure fallback, which is additive and guarded by the same reentrancy lock. |
| uninitialized-state | `EscrowBase._milestones` | False positive (mapping). |
| uninitialized-local | `FeeRouter.route` `referralPaid` | Assigned in both branches before use; benign. |
| unused-return | `_auditLog.log` inside try | Intentional (best-effort). |
| shadowing-local | `IAgentEscrowV2.setModules` parameter names | Cosmetic; renamed to `_`-suffixed in fix commit. |
| timestamp | expiry / review window comparisons | Inherent; 2-second Base blocks make the manipulation window irrelevant against 1-hour minimum deadlines and 7-day windows. |
| missing-zero-check | `FeeRouter.setReferral(0)` | Zero is the documented "disable referral" value. |
| low-level-calls | `_payOut`, `routeFeeSelf` self-call | Required for the fallback semantics; return data is decoded and checked. |
| Aderyn H-1 "state change after external call" | same sites as Slither reentrancy | Same verdict as above. |

## 5. Residual risks (accepted, documented)

- No external audit firm yet. Fee switch stays at 0 and the stack goes to Base Sepolia first.
- Reputation is only as trustworthy as the set of authorized writers (Escrow only at launch).
- Operator-key compromise blast radius is bounded only by the kill switch; SDKs default to registering one.

## 6. Final numbers (branch `security/v2-audit`)

| Metric | Value |
|---|---|
| `forge test` (whole repo) | 1,863 passed (1,138 v1 + 725 v2) |
| v2 test functions | 721 across unit, integration, audit regressions, invariants, symbolic |
| Audit regressions | 87 (every finding in §3 that changed code) |
| Coverage (v2) | 100% lines and functions, 876/877 lines |
| Invariants | 5 × 300,000 calls, 0 violations |
| Halmos | 3/3 properties proven |
| Slither / Aderyn | no exploitable findings (§4) |
| SDK unit / e2e | TS 51 / 27 checks, Python 59 / 43 checks against a local deployment of the final contracts |

### Fix commits
All fixes are on `security/v2-audit` and land in one PR so reviewers can diff the audited commit (`81684aa`) against the fixed one.

### What changed in the model (summary for integrators)
- A job is an **offer** until the provider calls `acceptJob`.
- `settleExpired` replaces `refundExpired`: submitted work pays the provider, unsubmitted work refunds the client, whoever calls it and whether the job was Open or Disputed.
- Submissions stop at the deadline; three rejections close a milestone; rejections are only possible inside the 7-day review window.
- Reputation needs ≥ $10 at stake, is capped at 10 events per pair, and is neutral on an even split.
- Ownership is two-step everywhere; kill-switch session resets are principal-only; fee routing uses bounded allowances and reports referral failures.
