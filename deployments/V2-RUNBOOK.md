# v2 Core Deploy Runbook (CEO, deployer key required)

Everything below is copy-paste. Run from `nexusweb3-protocols/` on a machine with Foundry and the deployer key.

## 0. Prerequisites

```bash
cd ~/Desktop/Nexusweb3/nexusweb3-protocols
git checkout v2/core-stack && git pull
forge build && forge test --match-path 'test/v2/*'      # must be all green
export PRIVATE_KEY=0x...                                # deployer (owner of all v1 contracts)
export BASESCAN_API_KEY=...                             # for --verify
```

Optional env (defaults in `script/v2/DeployCore.s.sol`):

| Var | Default | Notes |
|---|---|---|
| `OWNER` | deployer | ownership is two-step (`Ownable2Step`) on all six owned contracts — set to the multisig once you have one, then complete step 1b |
| `TREASURY` | owner | fee sink |
| `STAKING_RECIPIENT` | treasury | point at AgentStaking (v1) or a pool later |
| `REFERRAL` | 0 | v1 AgentReferral `0xc7774DEBC022Eb5A1cE619F612e85AD40bd6D9A7`; if set, also run step 3b |
| `ERC8004_REGISTRY` | 0 | Base canonical: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| `PAYMENT_TOKEN` | Base USDC | Sepolia USDC: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`; the escrow constructor reverts `ZeroAddress` if this address has no code, so a typo'd or EOA address fails fast at deploy instead of on first job |
| `ESCROW_FEE_BPS` | 0 | keep 0 until there is usage |

### 0b. If `OWNER` != deployer (two-step ownership)

`AgentIdentityV2`, `AgentReputationV2`, `AgentAuditLogV2`, `AgentKillSwitchV2`, `AgentEscrowV2`,
and `FeeRouter` are all `Ownable2Step`. `DeployCore.s.sol` calls `transferOwnership(OWNER)` on
each, but that only *proposes* the new owner — nothing transfers until the new owner calls
`acceptOwnership()` itself, on every one of the six contracts, from `OWNER`'s own key:

```bash
CHAINID=8453   # or 84532 for Sepolia
DEPLOY_JSON=deployments/v2-$CHAINID.json
for C in AgentIdentityV2 AgentReputationV2 AgentAuditLogV2 AgentKillSwitchV2 AgentEscrowV2 FeeRouter; do
  ADDR=$(jq -r .$C $DEPLOY_JSON)
  echo "acceptOwnership: $C ($ADDR)"
  cast send --rpc-url $RPC --private-key $NEW_OWNER_KEY $ADDR "acceptOwnership()"
done
```

Until every `acceptOwnership()` call lands, the deployer key remains the live owner (able to set
fees, modules, and pause). For the mainnet run, `OWNER` should be a multisig, not an EOA — run the
loop above from the multisig's own transaction flow (e.g. Safe), not a single private key.

## 1. Base Sepolia dry run (do this first)

```bash
export ERC8004_REGISTRY=0x0000000000000000000000000000000000000000
export PAYMENT_TOKEN=0x036CbD53842c5426634e7929541eC2318f3dCF7e
forge script script/v2/DeployCore.s.sol --rpc-url https://sepolia.base.org --broadcast --verify -vvv
cat deployments/v2-84532.json
```

Smoke test on Sepolia (replace addresses from the JSON):

```bash
RPC=https://sepolia.base.org
ESCROW=$(jq -r .AgentEscrowV2 deployments/v2-84532.json)
REP=$(jq -r .AgentReputationV2 deployments/v2-84532.json)
KS=$(jq -r .AgentKillSwitchV2 deployments/v2-84532.json)
LOG=$(jq -r .AgentAuditLogV2 deployments/v2-84532.json)
FR=$(jq -r .FeeRouter deployments/v2-84532.json)
# every one of these must print "true" — this is exactly what v1 never had
cast call --rpc-url $RPC $REP "isAuthorizedProtocol(address)(bool)" $ESCROW
cast call --rpc-url $RPC $KS  "isAuthorizedProtocol(address)(bool)" $ESCROW
cast call --rpc-url $RPC $LOG "isAuthorizedProtocol(address)(bool)" $ESCROW
cast call --rpc-url $RPC $FR  "isAuthorizedProtocol(address)(bool)" $ESCROW
cast call --rpc-url $RPC $ESCROW "reputation()(address)"
```

Then run the SDK e2e against Sepolia (see `sdk/README.md`).

## 2. Base mainnet

```bash
export ERC8004_REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
unset PAYMENT_TOKEN
export TREASURY=0xF98B46456565d34a3a580963D8cb7B3aBDff7a85
forge script script/v2/DeployCore.s.sol --rpc-url https://mainnet.base.org --broadcast --verify -vvv
cat deployments/v2-8453.json
```

Repeat the four `isAuthorizedProtocol` checks with `RPC=https://mainnet.base.org` and the 8453 JSON.

### 3b. Only if REFERRAL was set

The v1 `AgentReferral` contract must call `authorizeProtocol(FeeRouter)` on itself before it will
pay out referral fees for v2 jobs. `DeployCore.s.sol` attempts this automatically during `_wire`
using the deployer key, and logs a loud `WARNING` if it fails (the deployer usually isn't
`AgentReferral`'s owner). Check the deploy output; if you see the warning, run it manually from
whichever key does own `AgentReferral`:

```bash
cast send --rpc-url https://mainnet.base.org --private-key $REFERRAL_OWNER_KEY \
  0xc7774DEBC022Eb5A1cE619F612e85AD40bd6D9A7 "authorizeProtocol(address)" $(jq -r .FeeRouter deployments/v2-8453.json)
```

Until this succeeds, `route()` will hit `ReferralCallFailed` for every job with a referred agent —
routing still completes (staking/treasury get the referral's share) but no one gets paid a
referral fee.

## 3. Pause deprecated v1 contracts (mainnet)

These have zero usage and are superseded or unsafe (see `docs/DEPRECATIONS.md`). Pausing stops new deposits; withdrawals stay open on every v1 contract.

```bash
RPC=https://mainnet.base.org
for A in \
  0xF4800032959da18385b3158F9F2aD5BD586C85De \
  0x7110D3dB77038F19161AFFE13de8D39d624562D0 \
  0x9fA51922DDc788e291D96471483e01eE646efCC0 \
  0x610a5EbF726Dc3CFD1804915A9724B6825e21B71 \
  0x2E3394EcB00358983183f08D4C5B6dB60f85EE3B \
  0x29483A116B8D252Dc8bb1Ee057f650da305AA8b7 \
  0xA621CCaDA114A7E40e35dEFAA1eb678244cF788E \
  0x9027fD25e131D57B2D4182d505F20C2cF2227Cc4 \
  0xA346535515C6aA80Ec0bb4805e029e9696e5fa08 \
  0xef53C81a802Ecc389662244Ab2C65a612FBf3E27 \
  0x2Bf370a377dBfD45EDF36d1ede218D4fd2071eb1 \
  0xa736ad09d2e99a87910a04b5e445d7ed90f95efb \
  0x6a125ddaaf40cc773307fb312e5e7c66b1e551f3 \
  0xc84f118aea77fd1b6b07ce1927de7c7ae27fd9bf \
  0x6b8ebe897751e3c59ea95f28832c3b70de221cce \
  0x6E7350598d12809ccc98985440aEcb09CE728bbf \
  0x3e511326E22d291f2A3c5516b09318a34DC01152 \
  0xD3B07218A58cC75F0e47cbB237D7727970028a6E \
  0x470736BFE536A0127844C9Ce3F1aa2c0B712A4Fd \
  0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60 \
  0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16 \
  0xBbdaC522879d7DE4108C4866a55e215A3d896380 \
  0xd9B138692b41D9a3E527fE4C55A7A9a8406CE336 ; do
  echo "pause $A"; cast send --rpc-url $RPC --private-key $PRIVATE_KEY $A "pause()"
done
```

(Bridge, Launchpad, Scheduler, Oracle, Voting, Storage, Messaging, Auction, Split, Insights, KillSwitch v1, KYA, AuditLog v1, Bounty, Milestone, Subscription, Insolvency, Escrow v1, Market, Registry v1, Reputation v1, Insurance, Governance.)

Left running: AgentVaultFactory, AgentYield, AgentStaking, AgentWhitelist, AgentLicense, AgentReferral, AgentCollective, NexusToken.

## 4. After deploy

1. Paste the 8453 JSON addresses into `README.md` (v2 table) and `deployments/DEPLOYMENTS.md`.
2. If `OWNER` != deployer, complete step 0b: have the new owner (multisig, ideally) call
   `acceptOwnership()` on all six `Ownable2Step` contracts. Until then the deployer key is still
   the live owner.
3. Register our own agents (the treasury wallet) via the SDK — first non-zero usage.
4. Commit + push.
