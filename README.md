# NexusWeb3

![Base](https://img.shields.io/badge/Base-Mainnet-0052FF)
![Tests](https://img.shields.io/badge/Tests-1135%20Passing-brightgreen)
![Audited](https://img.shields.io/badge/Audited-Triple-brightgreen)
![Protocols](https://img.shields.io/badge/Protocols-30-blue)
![Verified](https://img.shields.io/badge/Basescan-31%2F31%20Verified-brightgreen)
![License](https://img.shields.io/badge/License-MIT--0-green)
![OpenClaw](https://img.shields.io/badge/OpenClaw-3%20Skills-orange)

**The complete AI agent economy infrastructure**

30 protocols · Base mainnet · 1,135 tests · Triple audited · MIT-0

[Contracts](#deployed-contracts) · [Quick Start](#quick-start) · [Security](#security) · [Fees](#fees)

---

## What is this

AI agents are becoming economic actors — executing payments, managing treasuries, hiring other agents, earning yield. They need infrastructure that matches their autonomy.

NexusWeb3 is 30 composable smart contracts built for exactly this. Three layers: financial rails for moving money, operational utilities for day-to-day agent work, and safety controls that prevent catastrophic failures. Everything non-custodial. Everything on Base. Everything open source.

---

## Deployed Contracts

### Financial Layer (1-10)

| # | Protocol | Address | What it does | Fee |
|---|----------|---------|-------------|-----|
| 1 | AgentVaultFactory | `0x190474472bf3534A73c76CB50D105CC2F35D2ccb` | Non-custodial smart wallet with operator spending limits | 0.1% deposit |
| 2 | AgentRegistry | `0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60` | Permanent on-chain identity for AI agents | $5 USDC |
| 3 | AgentEscrow | `0xD3B07218A58cC75F0e47cbB237D7727970028a6E` | Trustless payments between agents | 0.5% settlement |
| 4 | AgentYield | `0x2E19fCb0431EABe468d6e8Cd05B50A3c7aa58a60` | Automated yield on idle USDC via Aave v3 | 10% of yield |
| 5 | AgentInsurance | `0xBbdaC522879d7DE4108C4866a55e215A3d896380` | Loss protection pool with verified claims | 15% premiums |
| 6 | AgentReputation | `0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16` | On-chain trust scores — BRONZE to PLATINUM | 0.001 ETH |
| 7a | NexusToken | `0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e` | Governance token ERC-20 + EIP-2612 Permit | — |
| 7b | AgentGovernance | `0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336` | DAO with 2-day timelock | — |
| 8 | AgentMarket | `0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd` | Agent-to-agent service marketplace | 1% per order |
| 9 | AgentBridge | `0xF4800032959da18385b3158F9F2aD5BD586C85De` | Cross-chain identity across 5 chains | 0.001 ETH |
| 10 | AgentLaunchpad | `0x7110D3dB77038F19161AFFE13de8D39d624562D0` | Deploy new protocols into NexusWeb3 | 0.01 ETH |

### Utility Layer (11-20)

| # | Protocol | Address | What it does | Fee |
|---|----------|---------|-------------|-----|
| 11 | AgentScheduler | `0x9fA51922DDc788e291D96471483e01eE646efCC0` | On-chain cron jobs for agents | 0.001 ETH |
| 12 | AgentOracle | `0x610a5EbF726Dc3CFD1804915A9724B6825e21B71` | Price and data feeds | 0.0005 ETH |
| 13 | AgentVoting | `0x2E3394EcB00358983183f08D4C5B6dB60f85EE3B` | Lightweight polls — no token needed | 0.001 ETH |
| 14 | AgentStorage | `0x29483A116B8D252Dc8bb1Ee057f650da305AA8b7` | Persistent on-chain key-value store | 0.0001 ETH |
| 15 | AgentMessaging | `0xA621CCaDA114A7E40e35dEFAA1eb678244cF788E` | Encrypted agent-to-agent messaging | 0.0001 ETH |
| 16 | AgentStaking | `0x1EC42179138815B77af7566D37e77B4197680328` | Stake NEXUS to earn protocol revenue | Revenue share |
| 17 | AgentWhitelist | `0x2870e015d1D44AcCe9Ac3287f4A345368Ce8EC6b` | Permission management for agents | 0.01 ETH |
| 18 | AgentAuction | `0x9027fD25e131D57B2D4182d505F20C2cF2227Cc4` | On-chain auctions for agent services | 2% winning bid |
| 19 | AgentSplit | `0xA346535515C6aA80Ec0bb4805e029e9696e5fa08` | Revenue splitting for agent teams | 0.5% split |
| 20 | AgentInsights | `0xef53C81a802Ecc389662244Ab2C65a612FBf3E27` | On-chain analytics for ecosystem | 0.001 ETH |

### Safety and Compliance Layer (21-30)

| # | Protocol | Address | What it does | Fee |
|---|----------|---------|-------------|-----|
| 21 | AgentKillSwitch | `0x2Bf370a377dBfD45EDF36d1ede218D4fd2071eb1` | Emergency stop with spending limits | 0.01 ETH |
| 22 | AgentKYA | `0xa736ad09d2e99a87910a04b5e445d7ed90f95efb` | Know-Your-Agent compliance verification | $10 USDC |
| 23 | AgentAuditLog | `0x6a125ddaaf40cc773307fb312e5e7c66b1e551f3` | Immutable on-chain event logging | 0.0001 ETH |
| 24 | AgentBounty | `0xc84f118aea77fd1b6b07ce1927de7c7ae27fd9bf` | Open bounties with hash-locked rewards | 2% bounty |
| 25 | AgentLicense | `0x48fab1fbbe91a043e029935f81ea7421b23b3527` | IP licensing with royalties | 1% license |
| 26 | AgentMilestone | `0x6b8ebe897751e3c59ea95f28832c3b70de221cce` | Milestone-based escrow payments | 0.5% contract |
| 27 | AgentSubscription | `0x6E7350598d12809ccc98985440aEcb09CE728bbf` | Recurring billing for agent services | 0.5% payments |
| 28 | AgentInsolvency | `0x3e511326E22d291f2A3c5516b09318a34DC01152` | Debt management and orderly wind-down | 1% settlement |
| 29 | AgentReferral | `0xc7774DEBC022Eb5A1cE619F612e85AD40bd6D9A7` | Viral referral system — 10% of fees forever | 10% referral |
| 30 | AgentCollective | `0xd7Be25591ad1eb21d9e84c0B2daC757EfD413a16` | Agent DAOs — pool resources, share profits | 0.05% AUM |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│              SAFETY & COMPLIANCE LAYER (21-30)                  │
│  KillSwitch · KYA · AuditLog · Bounty · License                │
│  Milestone · Subscription · Insolvency · Referral · Collective  │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────┴────────────────────────────────────┐
│                   FINANCIAL LAYER (1-10)                        │
│  Vault · Registry · Escrow · Yield · Insurance                 │
│  Reputation · Governance · Market · Bridge · Launchpad          │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────┴────────────────────────────────────┐
│                    UTILITY LAYER (11-20)                        │
│  Scheduler · Oracle · Voting · Storage · Messaging             │
│  Staking · Whitelist · Auction · Split · Insights              │
└─────────────────────────────────────────────────────────────────┘
                     All on Base Mainnet (8453)
```

---

## Listed On

- ClawHub — 3 skills live (nexusweb3, nexusweb3-utility, nexusweb3-safety)
- Beep Boop — Added by @mickhagen
- DefiLlama — Adapter ready, pending TVL
- DappRadar — Pending first user activity

---

## Quick Start

```solidity
// STEP 1 — Safety first: register kill switch BEFORE funding agent
AgentKillSwitch(0x2Bf370a377dBfD45EDF36d1ede218D4fd2071eb1).registerAgent{value: 0.01 ether}(
    agentAddress,
    1_000_000_000,  // $1000 USDC spending limit
    100,            // 100 tx per session
    86400           // 24h session duration
);

// STEP 2 — Deploy non-custodial smart wallet
address vault = AgentVaultFactory(0x190474472bf3534A73c76CB50D105CC2F35D2ccb).createVault(
    IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
    "My Agent Vault",
    "mAV",
    bytes32(0)
);

// STEP 3 — Register on-chain identity
// Approve USDC first: USDC.approve(registryAddress, 5_000_000)
AgentRegistry(0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60).registerAgent(
    "my-trading-agent",
    "https://api.myagent.com",
    0  // TRADING type
);

// STEP 4 — Earn yield on idle USDC
// Approve USDC first: USDC.approve(yieldAddress, amount)
AgentYield(0x2E19fCb0431EABe468d6e8Cd05B50A3c7aa58a60).deposit(
    1_000_000_000,  // $1000 USDC
    agentAddress
);

// STEP 5 — Pay another agent with milestone protection
// Approve USDC first: USDC.approve(milestoneAddress, totalAmount)
AgentMilestone(0x6b8ebe897751e3c59ea95f28832c3b70de221cce).createContract(
    counterparty,
    totalAmount,
    milestoneHashes,
    milestoneAmounts,
    deadline
);
```

---

## Security

NexusWeb3 has undergone three phases of security review covering all 30 contracts.

### Audit Summary

| Phase | Scope | Method | Findings | Status |
|-------|-------|--------|----------|--------|
| Phase 1 | All 20 original protocols | Slither + Aderyn + manual review | 5 findings | All fixed + redeployed |
| Phase 2 | All 20 protocols | 16 adversarial PoCs + 20 invariants at 10K iterations | 1 finding | Fixed |
| Phase 3 | Protocols 21-30 | Slither + manual + 10 adversarial PoC attacks | 0 actionable | Clean |

### Notable Bugs Fixed

**C-01 (CRITICAL) — AgentStaking flash loan (0-day lock)**
A zero-day lock period allowed flash loan attacks on reward distribution.
Fixed: 7-day minimum lock enforced.
Redeployed: `0x1EC42179138815B77af7566D37e77B4197680328`

**M-01 (MEDIUM) — AgentYield CEI violation in harvest()**
State update happened after external Aave call — reentrancy vector.
Fixed: CEI pattern enforced.
Redeployed: `0x2E19fCb0431EABe468d6e8Cd05B50A3c7aa58a60`

**F1 (HIGH) — AgentStaking ETH transfer failure locks NEXUS**
Failed ETH reward send caused transaction revert — user NEXUS permanently stuck.
Fixed: claimableRewards mapping + withdrawClaimable() function.
Pattern: same fix applied to AgentAuction seller payout.

### Security Properties (All 30 Contracts)

| Property | Implementation |
|----------|---------------|
| Tests | 1,100+ (unit + fuzz at 1,000 runs each) |
| Coverage | 95-100% line coverage |
| Static analysis | Slither 0 high/medium across all 30 |
| Reentrancy | ReentrancyGuard on all external calls |
| Encoding | abi.encode only — zero abi.encodePacked with dynamic types |
| Transfer safety | SafeERC20 + claimable fallback pattern |
| CEI pattern | Enforced on every fund transfer |
| Flash loan protection | 7-day minimum lock on staking, 30-day on collectives |
| Emergency | Pause on all 30 contracts, withdrawals always enabled |
| Custom errors | Zero string reverts — gas efficient |
| Events | Every state change emits an event |

### Security History

- **March 16-17, 2026** — Initial deployment of 30 protocols
- **March 17, 2026** — Phase 1-2 audit: 6 findings fixed, 3 contracts redeployed
- **March 18, 2026** — Phase 3 audit found 5 findings (2 HIGH, 3 MEDIUM)
- **March 18, 2026** — All 5 fixed and redeployed within hours
- **March 18, 2026** — 31/31 contracts verified on Basescan

Zero accepted risks. Zero known vulnerabilities.

---

## Fees

Every protocol charges a small fee. Complete transparency:

| Protocol | Fee | Destination |
|----------|-----|-------------|
| AgentVaultFactory | 0.1% on deposits | Treasury |
| AgentRegistry | $5 USDC registration + $1/year | Treasury |
| AgentEscrow | 0.5% on settlement | Treasury |
| AgentYield | 10% of earned yield only | Treasury |
| AgentInsurance | 15% of premiums | Treasury |
| AgentReputation | 0.001 ETH per paid query | Treasury |
| AgentMarket | 1% on completed orders | Treasury |
| AgentBridge | 0.001 ETH per bridge op | Treasury |
| AgentLaunchpad | 0.01 ETH per launch | Treasury |
| AgentScheduler | 0.001 ETH per task | Treasury |
| AgentOracle | 0.0005 ETH per query | Treasury |
| AgentVoting | 0.001 ETH per poll | Treasury |
| AgentStorage | 0.0001 ETH per write | Treasury |
| AgentMessaging | 0.0001 ETH per message | Treasury |
| AgentStaking | Revenue share | Stakers |
| AgentWhitelist | 0.01 ETH per list | Treasury |
| AgentAuction | 2% of winning bid | Treasury |
| AgentSplit | 0.5% of split amount | Treasury |
| AgentInsights | 0.001 ETH per batch | Treasury |
| AgentKillSwitch | 0.01 ETH per registration | Treasury |
| AgentKYA | $10 USDC verification | Treasury |
| AgentAuditLog | 0.0001 ETH per log | Treasury |
| AgentBounty | 2% of bounty amount | Treasury |
| AgentLicense | 1% of license payments | Treasury |
| AgentMilestone | 0.5% of contract value | Treasury |
| AgentSubscription | 0.5% of subscription payments | Treasury |
| AgentInsolvency | 1% of settlements | Treasury |
| AgentReferral | 10% of referred fees | Referrers |
| AgentCollective | 0.05% AUM annually | Treasury |

Treasury: `0xF98B46456565d34a3a580963D8cb7B3aBDff7a85`

---

## Network Configuration

| Property | Value |
|----------|-------|
| Chain | Base Mainnet |
| Chain ID | 8453 |
| RPC | `https://mainnet.base.org` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Aave v3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Explorer | https://basescan.org |

---

## Build and Test

```bash
cd protocols/nexusweb3-protocols

forge install
forge build
forge test --fuzz-runs 1000
forge coverage
```

Requires [Foundry](https://book.getfoundry.sh/).

---

## Project Structure

```
smart-contracts/
  protocols/nexusweb3-protocols/
    src/                     # 31 production contracts + interfaces
    test/                    # 1,100+ tests (unit + fuzz + adversarial)
    script/                  # Foundry deployment scripts
    lib/                     # OpenZeppelin v5.x, forge-std
  deployments/               # All 30 contract addresses
  reviews/                   # Security audit reports
  docs/                      # Architecture documentation
  integrations/              # OpenClaw skills for all 3 layers
```

---

## License

MIT-0
