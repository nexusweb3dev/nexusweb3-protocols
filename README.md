<p align="center">
  <h1 align="center">NexusWeb3</h1>
  <p align="center"><strong>Financial infrastructure for the AI agent economy</strong></p>
  <p align="center">10 protocols &middot; Base mainnet &middot; 358 tests &middot; Audited</p>
</p>

<p align="center">
  <a href="https://basescan.org/address/0x1F28579F8C2dffde8746169116bb3a4d9E516f5A">Basescan</a> &middot;
  <a href="#deployed-contracts">Contracts</a> &middot;
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#security">Security</a>
</p>

---

## What is this?

AI agents need money rails. Not custodial APIs — real on-chain infrastructure they own and control.

NexusWeb3 is 10 composable smart contracts that give any AI agent a complete financial stack: a wallet, an identity, trustless payments, passive yield, insurance, reputation, a marketplace, cross-chain portability, governance, and the ability to launch new protocols. Everything runs on Base. Everything is non-custodial.

## Deployed Contracts

All contracts are live on **Base mainnet** (Chain ID `8453`).

| | Protocol | Address | What it does |
|---|---|---|---|
| 1 | **AgentVault** | [`0x1F28...5A`](https://basescan.org/address/0x1F28579F8C2dffde8746169116bb3a4d9E516f5A) | Smart wallet with operator spending limits |
| 2 | **AgentRegistry** | [`0x6F73...C60`](https://basescan.org/address/0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60) | On-chain identity — $5 to register |
| 3 | **AgentEscrow** | [`0xD3B0...6E`](https://basescan.org/address/0xD3B07218A58cC75F0e47cbB237D7727970028a6E) | Trustless payments between agents |
| 4 | **AgentYield** | [`0x4c5a...74`](https://basescan.org/address/0x4c5aA529Ef17f30D49497b3c7fe108A034FD6474) | Earn yield on idle USDC via Aave v3 |
| 5 | **AgentInsurance** | [`0xBbda...80`](https://basescan.org/address/0xBbdaC522879d7DE4108C4866a55e215A3d896380) | Loss protection pool |
| 6 | **AgentReputation** | [`0x08Fa...16`](https://basescan.org/address/0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16) | On-chain trust scores |
| 7 | **NEXUS Token** | [`0x7a75...2e`](https://basescan.org/address/0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e) | Governance token (ERC-20 + Permit) |
| | **AgentGovernance** | [`0xd9B1...36`](https://basescan.org/address/0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336) | DAO — propose, vote, execute |
| 8 | **AgentMarket** | [`0x4707...Fd`](https://basescan.org/address/0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd) | Service marketplace for agents |
| 9 | **AgentBridge** | [`0xF480...De`](https://basescan.org/address/0xF4800032959da18385b3158F9F2aD5BD586C85De) | Cross-chain identity (5 chains) |
| 10 | **AgentLaunchpad** | [`0x7110...D0`](https://basescan.org/address/0x7110D3dB77038F19161AFFE13de8D39d624562D0) | Deploy new agent protocols |

## Quick Start

```solidity
// 1. Deploy a wallet for your agent
address vault = AgentVaultFactory(0x1F28...5A).createVault(USDC, "My Vault", "mV", salt);

// 2. Register on-chain identity
AgentRegistry(0x6F73...C60).registerAgent("my-agent", "https://api.me", 3);

// 3. Pay another agent
AgentEscrow(0xD3B0...6E).createEscrow(recipient, 50_000_000, deadline);

// 4. Earn yield on idle USDC
AgentYield(0x4c5a...74).deposit(1_000_000_000, myAddress);

// 5. Check reputation before transacting
uint256 score = AgentReputation(0x08Fa...16).getScoreFree(counterparty);
```

Your agent needs a small amount of ETH on Base for gas (< $0.01/tx) and USDC for protocol interactions.

## How it works

```
                         +-----------------+
                         |  AgentVault     |  Smart wallet
                         |  (ERC-4626)     |  with operator limits
                         +--------+--------+
                                  |
                    +-------------+-------------+
                    |                           |
             +------+------+            +------+------+
             | AgentRegistry|            | AgentYield  |  Deposit idle USDC
             | Identity     |            | Aave v3     |  earn 4-8% APY
             +------+------+            +-------------+
                    |
        +-----------+-----------+
        |           |           |
  +-----+-----+ +--+---+ +----+------+
  |AgentEscrow| |Market | |Insurance  |
  |Payments   | |Buy/   | |Loss       |
  |0.5% fee   | |Sell   | |protection |
  +-----------+ +-------+ +-----------+
        |
  +-----+------+     +-----------+     +------------+
  |AgentBridge  |     |Reputation |     |Governance  |
  |Cross-chain  |     |Trust      |     |NEXUS DAO   |
  |5 chains     |     |scores     |     |Timelock    |
  +-------------+     +-----------+     +------------+
                                              |
                                        +-----+------+
                                        |Launchpad   |
                                        |Deploy new  |
                                        |protocols   |
                                        +------------+
```

## Build & Test

```bash
# Clone
git clone https://github.com/nexusweb3dev/nexusweb3-protocols.git
cd nexusweb3-protocols

# Install dependencies
forge install

# Build all contracts
forge build

# Run 358 tests (including fuzz @ 1000 runs)
forge test

# Coverage report
forge coverage
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

## Security

| | |
|---|---|
| **Tests** | 358 (unit + fuzz at 1000 runs each) |
| **Coverage** | 95-100% line coverage on all contracts |
| **Static analysis** | Slither v0.11.5 — 0 high/medium findings |
| **Dependencies** | OpenZeppelin v5.x |
| **Reentrancy** | `ReentrancyGuard` on all state-changing functions |
| **Encoding** | `abi.encode` only — never `abi.encodePacked` with dynamic types |
| **Emergency** | `Pausable` on all protocols, withdrawals always enabled |

All contracts follow CEI (Checks-Effects-Interactions) pattern. Custom errors instead of string reverts. Events on every state change.

## Network

| | |
|---|---|
| Chain | Base Mainnet |
| Chain ID | `8453` |
| RPC | `https://mainnet.base.org` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Aave v3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |

## Project Structure

```
src/
  AgentVault.sol              # ERC-4626 vault + operator permissions
  AgentVaultFactory.sol       # CREATE2 vault deployer
  AgentRegistry.sol           # On-chain agent identity
  AgentEscrow.sol             # Trustless payment escrow
  AgentYield.sol              # Aave v3 yield vault
  AgentInsurance.sol          # Insurance protection pool
  AgentReputation.sol         # Trust scoring system
  NexusToken.sol              # NEXUS governance token
  AgentGovernance.sol         # DAO with timelock
  AgentMarket.sol             # Service marketplace
  AgentBridge.sol             # Cross-chain identity
  AgentLaunchpad.sol          # Protocol deployment platform
  interfaces/                 # All contract interfaces
test/                         # 358 tests
script/                       # Foundry deployment scripts
```

## Fees

Every protocol charges a small fee. Full transparency:

| Protocol | Fee | Goes to |
|----------|-----|---------|
| AgentVault | 0.1% on deposits | Treasury |
| AgentRegistry | $5 registration + $1/year | Treasury |
| AgentEscrow | 0.5% on settlement | Treasury |
| AgentYield | 10% of earned yield | Treasury |
| AgentInsurance | 15% of premiums | Treasury |
| AgentReputation | 0.001 ETH per paid query | Treasury |
| AgentMarket | 1% on completed orders | Treasury |
| AgentBridge | 0.001 ETH per bridge op | Treasury |
| AgentLaunchpad | 0.01 ETH per launch | Treasury |

## License

MIT
