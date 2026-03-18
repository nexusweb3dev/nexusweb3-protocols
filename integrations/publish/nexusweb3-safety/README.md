# NexusWeb3 Safety Layer

Read-only API reference for NexusWeb3 safety and compliance protocols 21-30 on Base mainnet.

This skill provides contract addresses, function signatures, and usage examples for querying on-chain state. No credentials required for read operations.

## Protocols Covered

| # | Protocol | Address | What it does |
|---|----------|---------|-------------|
| 21 | AgentKillSwitch | `0x2Bf370a377dBfD45EDF36d1ede218D4fd2071eb1` | Emergency stop with spending limits |
| 22 | AgentKYA | `0xa736ad09d2e99a87910a04b5e445d7ed90f95efb` | Know-Your-Agent compliance |
| 23 | AgentAuditLog | `0x6a125ddaaf40cc773307fb312e5e7c66b1e551f3` | Tamper-proof audit trail |
| 24 | AgentBounty | `0xc84f118aea77fd1b6b07ce1927de7c7ae27fd9bf` | Hash-locked bounties |
| 25 | AgentLicense | `0x48fab1fbbe91a043e029935f81ea7421b23b3527` | IP licensing with royalties |
| 26 | AgentMilestone | `0x6b8ebe897751e3c59ea95f28832c3b70de221cce` | Milestone-based payments |
| 27 | AgentSubscription | `0x6E7350598d12809ccc98985440aEcb09CE728bbf` | Recurring billing |
| 28 | AgentInsolvency | `0x3e511326E22d291f2A3c5516b09318a34DC01152` | Debt management and wind-down |
| 29 | AgentReferral | `0xc7774DEBC022Eb5A1cE619F612e85AD40bd6D9A7` | Viral referral network |
| 30 | AgentCollective | `0xd7Be25591ad1eb21d9e84c0B2daC757EfD413a16` | Agent DAOs with pooled treasuries |

## Usage

This is an instruction-only skill. Install it and your agent can query any of the 10 safety protocols using the documented view functions. No credentials, no downloads, no executable code.

For write operations that sign transactions, install the `nexusweb3` financial skill which includes operator key setup.

## Security

All 30 NexusWeb3 contracts are triple-audited with Slither, 1,100+ Foundry tests, and 30 adversarial PoC attack scenarios. Source code at https://github.com/nexusweb3dev/nexusweb3-protocols.

## License

MIT-0
