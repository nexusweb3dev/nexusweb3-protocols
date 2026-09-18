# Deprecations (v2, September 2026)

Every v1 contract below is deployed on Base mainnet with **zero transactions and zero funds** as of 2026-09-18. They are deprecated, not exploited. Each one is either superseded by a v2 contract, replaced by free public infrastructure that agent frameworks already integrate, or unsafe by design for real use. All v1 contracts keep `withdraw`/exit paths open while paused.

| v1 contract | Address | Why | Replacement |
|---|---|---|---|
| AgentRegistry | `0x6F73…eC60` | $5 fee, expiring, address-keyed, nothing read it | `AgentIdentityV2` (free, ERC-8004 link) |
| AgentEscrow | `0xD3B0…8a6E` | recipient could release funds to itself; owner-only disputes | `AgentEscrowV2` |
| AgentMilestone | `0x6b8e…1cce` | answer hash public; owner-only disputes | `AgentEscrowV2` (milestones) |
| AgentMarket | `0x4707…A4Fd` | seller loses by default after 1 day; owner-only disputes | `AgentEscrowV2` + off-chain listing in `agentURI` |
| AgentAuction | `0x9027…7Cc4` | no deliverable on-chain, no anti-snipe, ETH listing fee | `AgentEscrowV2` |
| AgentReputation | `0x08Fa…5f16` | zero authorized writers, paid reads | `AgentReputationV2` |
| AgentKillSwitch | `0x2Bf3…1eb1` | zero authorized protocols, ETH fee, permanent kill | `AgentKillSwitchV2` |
| AgentAuditLog | `0x6a12…51f3` | ETH fee per entry, protocols could not log for agents | `AgentAuditLogV2` |
| AgentLaunchpad | `0x7110…62D0` | paid directory entry, owner-verified | `AgentIdentityV2` |
| AgentBridge | `0xF480…85De` | bridges nothing; relayer EOA can forge identities | ERC-8004 (CAIP-10 identities) |
| AgentOracle | `0x610a…1B71` | owner-pushed numbers; free view defeats paid view | Chainlink / Pyth on Base |
| AgentScheduler | `0x9fA5…fCC0` | executes nothing; keeper can drain balance | Gelato / Chainlink Automation |
| AgentMessaging | `0xA621…788E` | plaintext in storage, unbounded arrays | XMTP |
| AgentInsights | `0xef53…f27` | manual dashboard as a contract, O(100) writes | subgraph / Dune |
| AgentVoting | `0x2E33…EE3B` | non-binding, ETH per vote, results visible before close | Snapshot |
| AgentStorage | `0x2948…A8b7` | public getter bypasses its own ACL | — (v3 candidate: agent memory) |
| AgentSplit | `0xA346…fa08` | owner can rewrite recipients; payers must call a function | 0xSplits |
| AgentBounty | `0xc84f…d9bf` | answer hash public | — (v3 candidate: commit-reveal) |
| AgentSubscription | `0x6E73…8bbf` | unpaid keeper, no reactivation | — (v3 candidate) |
| AgentInsolvency | `0x3e51…1152` | honour-system; disclosure #2 fix branch pending | — |
| AgentKYA | `0xa736…5efb` | zero verifiers, PII on-chain | — (v3: hashed attestations) |
| AgentInsurance | `0xBbda…6380` | payouts at owner discretion | — (v3: evidence-keyed claims) |
| AgentGovernance | `0xd9B1…E336` | live-balance voting, owner veto, owns nothing | OZ Governor later |

## Still supported from v1

AgentVaultFactory/AgentVault, AgentYield, AgentStaking, AgentWhitelist, AgentLicense, AgentReferral, AgentCollective, NexusToken. These are self-serve today. v2 `FeeRouter` can pay into AgentReferral and a staking recipient; AgentWhitelist/AgentCollective will be pointed at v2 Reputation in a follow-up release.
