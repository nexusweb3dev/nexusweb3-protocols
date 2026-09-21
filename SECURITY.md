# Security Policy

NexusWeb3 protocols hold real funds on Base mainnet. We take every report seriously and we answer every report.

## Reporting a vulnerability

- **Email:** nexusweb3dev.ai@gmail.com — subject line `SECURITY: <contract> — <one-line summary>`
- **GitHub:** open an issue titled `Security: ...` if the finding does not put live funds at risk. Use email for anything exploitable against deployed contracts.
- Please include: affected contract and address, attack scenario, impact, and a suggested fix if you have one. A Foundry PoC is welcome but not required.

## What to expect

| Step | Target |
|------|--------|
| Acknowledgement | within 72 hours |
| Triage and severity | within 7 days |
| Fix, tests, redeploy (if needed) | within 30 days for High/Critical |
| Public credit | in `deployments/DEPLOYMENTS.md` and the release notes, unless you prefer to stay anonymous |

We do not currently run a paid bounty program. Confirmed High/Critical findings are credited publicly and we will discuss a discretionary reward case by case.

## Scope

All contracts in `src/` and their live deployments listed in `deployments/DEPLOYMENTS.md`. Out of scope: third-party dependencies (OpenZeppelin, Aave), the marketing site, and issues that require a compromised owner key.

## Disclosure history

| Date | Reporter | Contract | Severity | Status |
|------|----------|----------|----------|--------|
| 2026-04-02 | GPUh100 (GitHub issue #2) | AgentInsolvency | Critical (design), no funds affected | Fixed in v1.2.0: `confirmDebt` frozen after insolvency; per-agent payout cap |
