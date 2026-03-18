# NexusWeb3 — Deployment Registry

**Network:** Base Mainnet (Chain ID: 8453)
**Owner:** `0xF98B46456565d34a3a580963D8cb7B3aBDff7a85`
**USDC:** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
**Aave v3 Pool:** `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`
**aBasUSDC:** `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB`

## Financial Layer (1-10)

| # | Contract | Address | Version | Fee | Tests | Audit |
|---|----------|---------|---------|-----|-------|-------|
| 1 | AgentVaultFactory | `0x190474472bf3534A73c76CB50D105CC2F35D2ccb` | v1.0.1 | 0.1% deposit | 32 | PASS |
| 2 | AgentRegistry | `0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60` | v1.0.0 | $5 reg + $1/yr | 28 | PASS |
| 3 | AgentEscrow | `0xD3B07218A58cC75F0e47cbB237D7727970028a6E` | v1.0.0 | 0.5% settlement | 34 | PASS |
| 4 | AgentYield | `0x2E19fCb0431EABe468d6e8Cd05B50A3c7aa58a60` | v1.0.1 | 10% of yield | 26 | PASS |
| 5 | AgentInsurance | `0xBbdaC522879d7DE4108C4866a55e215A3d896380` | v1.0.0 | 15% of premiums | 30 | PASS |
| 6 | AgentReputation | `0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16` | v1.0.0 | 0.001 ETH/query | 22 | PASS |
| 7a | NexusToken (NEXUS) | `0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e` | v1.0.0 | — | 8 | PASS |
| 7b | AgentGovernance | `0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336` | v1.0.0 | — | 24 | PASS |
| 8 | AgentMarket | `0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd` | v1.0.0 | 1% service fee | 32 | PASS |
| 9 | AgentBridge | `0xF4800032959da18385b3158F9F2aD5BD586C85De` | v1.0.0 | 0.001 ETH/bridge | 20 | PASS |
| 10 | AgentLaunchpad | `0x7110D3dB77038F19161AFFE13de8D39d624562D0` | v1.0.0 | 0.01 ETH/launch | 18 | PASS |

## Utility Layer (11-20)

| # | Contract | Address | Version | Fee | Tests | Audit |
|---|----------|---------|---------|-----|-------|-------|
| 11 | AgentScheduler | `0x9fA51922DDc788e291D96471483e01eE646efCC0` | v1.0.0 | 0.001 ETH/task | 24 | PASS |
| 12 | AgentOracle | `0x610a5EbF726Dc3CFD1804915A9724B6825e21B71` | v1.0.0 | 0.0005 ETH/query | 22 | PASS |
| 13 | AgentVoting | `0x2E3394EcB00358983183f08D4C5B6dB60f85EE3B` | v1.0.0 | 0.001 ETH/poll | 20 | PASS |
| 14 | AgentStorage | `0x29483A116B8D252Dc8bb1Ee057f650da305AA8b7` | v1.0.0 | 0.0001 ETH/write | 18 | PASS |
| 15 | AgentMessaging | `0xA621CCaDA114A7E40e35dEFAA1eb678244cF788E` | v1.0.0 | 0.0001 ETH/msg | 20 | PASS |
| 16 | AgentStaking | `0x1EC42179138815B77af7566D37e77B4197680328` | v1.0.2 | Revenue share | 30 | PASS |
| 17 | AgentWhitelist | `0x2870e015d1D44AcCe9Ac3287f4A345368Ce8EC6b` | v1.0.0 | 0.01 ETH/list | 22 | PASS |
| 18 | AgentAuction | `0x9027fD25e131D57B2D4182d505F20C2cF2227Cc4` | v1.0.1 | 2% winning bid | 38 | PASS |
| 19 | AgentSplit | `0xA346535515C6aA80Ec0bb4805e029e9696e5fa08` | v1.0.0 | 0.5% of split | 26 | PASS |
| 20 | AgentInsights | `0xef53C81a802Ecc389662244Ab2C65a612FBf3E27` | v1.0.0 | 0.001 ETH/batch | 20 | PASS |

## Safety and Compliance Layer (21-30)

| # | Contract | Address | Version | Fee | Tests | Audit |
|---|----------|---------|---------|-----|-------|-------|
| 21 | AgentKillSwitch | `0x2Bf370a377dBfD45EDF36d1ede218D4fd2071eb1` | v1.1.0 | 0.01 ETH/reg | 31 | PASS |
| 22 | AgentKYA | `0xa736ad09d2e99a87910a04b5e445d7ed90f95efb` | v1.0.0 | $10 USDC | 24 | PASS |
| 23 | AgentAuditLog | `0x6a125ddaaf40cc773307fb312e5e7c66b1e551f3` | v1.0.0 | 0.0001 ETH/log | 22 | PASS |
| 24 | AgentBounty | `0xc84f118aea77fd1b6b07ce1927de7c7ae27fd9bf` | v1.0.0 | 2% of bounty | 30 | PASS |
| 25 | AgentLicense | `0x48fab1fbbe91a043e029935f81ea7421b23b3527` | v1.0.0 | 1% of license | 26 | PASS |
| 26 | AgentMilestone | `0x6b8ebe897751e3c59ea95f28832c3b70de221cce` | v1.0.0 | 0.5% contract | 34 | PASS |
| 27 | AgentSubscription | `0x6E7350598d12809ccc98985440aEcb09CE728bbf` | v1.1.0 | 0.5% payments | 28 | PASS |
| 28 | AgentInsolvency | `0x3e511326E22d291f2A3c5516b09318a34DC01152` | v1.1.0 | 1% settlements | 72 | PASS |
| 29 | AgentReferral | `0xc7774DEBC022Eb5A1cE619F612e85AD40bd6D9A7` | v1.1.0 | 10% referral | 49 | PASS |
| 30 | AgentCollective | `0xd7Be25591ad1eb21d9e84c0B2daC757EfD413a16` | v1.1.0 | 0.05% AUM | 52 | PASS |

## Deployment Timeline

- **2026-03-16:** Financial Layer (1-10) deployed
- **2026-03-16:** Utility Layer (11-20) deployed
- **2026-03-16:** Safety Layer (21-27) deployed
- **2026-03-17:** AgentYield v1.0.1 redeployed (M-01 CEI fix)
- **2026-03-17:** AgentStaking v1.0.2 redeployed (C-01 flash loan fix)
- **2026-03-17:** AgentAuction v1.0.1 redeployed (claimable payout fix)
- **2026-03-17:** AgentInsolvency, AgentReferral, AgentCollective (28-30) deployed
- **2026-03-17:** Phase 3 audit fixes — 5 contracts redeployed (KillSwitch, Subscription, Insolvency, Referral, Collective)
- **2026-03-18:** AgentVaultFactory v1.0.1 redeployed (bytecode metadata fix, Basescan verified)
- **2026-03-18:** 5 safety contracts v1.1.0 redeployed with security patches + Basescan verified
- **2026-03-18:** All 31 contracts verified on Basescan — zero known vulnerabilities

## Security Summary

| Phase | Scope | Method | Findings | Status |
|-------|-------|--------|----------|--------|
| Phase 1 | All 20 protocols | Slither + Aderyn + manual | 5 findings | All fixed + redeployed |
| Phase 2 | All 20 protocols | 16 adversarial PoCs + invariants | 1 finding | Fixed |
| Phase 3 | Protocols 21-30 | Slither + manual + 10 PoC attacks | 0 actionable | Clean |

**Total tests:** 1,100+
**Fuzz runs:** 1,000 per fuzz test
**Slither:** 0 actionable findings across all 30 contracts

## Config Details

**NexusToken:** 100,000,000 NEXUS total supply, ERC-20 + EIP-2612 Permit
**AgentGovernance:** 100 NEXUS proposal threshold, 10% quorum, 2-day timelock
**AgentMarket:** 1% fee, $1 USDC minimum, 24h dispute window
**AgentBridge:** 5 chains (Base, Arbitrum, Optimism, Polygon, BNB)
**AgentLaunchpad:** 20 max protocols per deployer
**AgentStaking:** 7-day minimum lock, revenue sharing
**AgentInsolvency:** 1% platform fee, 0.001 ETH registration, permanent insolvency
**AgentReferral:** 10% referral rate, ETH + USDC rewards, 10-level cycle check
**AgentCollective:** 0.01 ETH deploy fee, 0.05% annual AUM, 30-day lock, soulbound ERC-1155
