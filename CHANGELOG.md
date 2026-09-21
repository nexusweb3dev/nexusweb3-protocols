# Changelog

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
