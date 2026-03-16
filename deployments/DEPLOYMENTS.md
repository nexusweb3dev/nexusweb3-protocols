# Deployment Registry — NexusWeb3 Protocols

## Base Mainnet (Chain ID: 8453) — PRODUCTION

| # | Contract | Address | Version | Fee/Revenue |
|---|----------|---------|---------|-------------|
| 1 | AgentVaultFactory | 0x1F28579F8C2dffde8746169116bb3a4d9E516f5A | v1.0.0 | 0.1% deposit |
| 2 | AgentRegistry | 0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60 | v1.0.0 | $5 reg + $1/yr |
| 3 | AgentEscrow | 0xD3B07218A58cC75F0e47cbB237D7727970028a6E | v1.0.0 | 0.5% settlement |
| 4 | AgentYield | 0x4c5aA529Ef17f30D49497b3c7fe108A034FD6474 | v1.0.0 | 10% of yield |
| 5 | AgentInsurance | 0xBbdaC522879d7DE4108C4866a55e215A3d896380 | v1.0.0 | 15% of premiums |
| 6 | AgentReputation | 0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16 | v1.0.0 | 0.001 ETH/query |
| 7a | NexusToken (NEXUS) | 0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e | v1.0.0 | Governance token |
| 7b | AgentGovernance | 0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336 | v1.0.0 | DAO voting |
| 8 | AgentMarket | 0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd | v1.0.0 | 1% service fee |
| 9 | AgentBridge | 0xF4800032959da18385b3158F9F2aD5BD586C85De | v1.0.0 | 0.001 ETH/bridge |
| 10 | AgentLaunchpad | 0x7110D3dB77038F19161AFFE13de8D39d624562D0 | v1.0.0 | 0.01 ETH/launch |

All contracts deployed 2026-03-16. Owner: 0xF98B46456565d34a3a580963D8cb7B3aBDff7a85

### Config Details

**Shared:**
- USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
- Aave Pool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
- aBasUSDC: 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
- Treasury: 0xF98B46456565d34a3a580963D8cb7B3aBDff7a85

**NexusToken:** 100,000,000 NEXUS total supply, ERC-20 + EIP-2612 Permit
**AgentGovernance:** 100 NEXUS proposal threshold, 10% quorum, 2-day timelock
**AgentMarket:** 1% fee, $1 USDC minimum, 24h dispute window
**AgentBridge:** 5 chains (Base, Arbitrum, Optimism, Polygon, BNB)
**AgentLaunchpad:** 20 max protocols per deployer

### Basescan
- https://basescan.org/address/0x1F28579F8C2dffde8746169116bb3a4d9E516f5A
- https://basescan.org/address/0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60
- https://basescan.org/address/0xD3B07218A58cC75F0e47cbB237D7727970028a6E
- https://basescan.org/address/0x4c5aA529Ef17f30D49497b3c7fe108A034FD6474
- https://basescan.org/address/0xBbdaC522879d7DE4108C4866a55e215A3d896380
- https://basescan.org/address/0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16
- https://basescan.org/address/0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e
- https://basescan.org/address/0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336
- https://basescan.org/address/0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd
- https://basescan.org/address/0xF4800032959da18385b3158F9F2aD5BD586C85De
- https://basescan.org/address/0x7110D3dB77038F19161AFFE13de8D39d624562D0
