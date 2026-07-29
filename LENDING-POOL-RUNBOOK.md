# Fabrica Lending Pool Upgrade Runbook

The beacon-based upgrade runbook for the Fabrica lending pool stack in
`contracts/`. (FabricaToken and the other Fabrica-owned contracts have their
own UUPS upgrade runbook in the `fabrica-land/fabrica-v3-contracts` repo.)

## Network Addresses

### Sepolia

| Contract                                | Address                                      | Notes                                          |
|-----------------------------------------|----------------------------------------------|------------------------------------------------|
| **UpgradeableBeacon** (WeightedRateERC1155CollectionPool target) | `0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E` | `upgradeTo(newImpl)` is the upgrade lever      |
| **Beacon owner**                        | `0xBF03076547a99857b796717faF4034dea94569dF` | `TESTNET_DEPLOYER_PRIVATE_KEY` in `.env`       |
| **PoolFactory** (ERC1967 proxy)         | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` | `createProxied(beacon, params)` spawns pools   |
| **PoolFactory owner**                   | `0xBF03076547a99857b796717faF4034dea94569dF` |                                                |
| **Pool (BeaconProxy)** — USDC + FabricaToken | `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` | The pool with live liquidity                   |
| **ERC1155CollateralWrapper**            | `0xf6E3932F8b4ef957f3E361CECBF1489Ea93cb086` | Pool constructor immutable                     |
| **EnglishAuctionCollateralLiquidator**  | `0xc780FEe561fc6E50493C496a53c62518971ba9EF` | Pool constructor immutable                     |
| **SimpleSignedPriceOracle**             | `0x522C7F01B535b36eca6b27C32A65Ee79e7c4df45` | Per-pool oracle, set via `initialize` params   |
| **ERC20DepositTokenImplementation**     | `0x479c18dcEB406C88a0E05c86b9Ca02B6B043507B` | Pool constructor immutable                     |
| **delegate.xyz V1 registry**            | `0x00000000000076A84feF008CDAbe6409d2FE638B` | Canonical (same on all chains)                 |
| **delegate.xyz V2 registry**            | `0x00000000000000447e69651d841bD8D104Bed493` | Canonical (same on all chains)                 |
| **Currency token** (pool param)         | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | Circle USDC on Sepolia                         |
| **Collateral token** (pool param)       | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` | FabricaToken on Sepolia                        |

(Addresses sourced from the live Sepolia chain — beacon at slot
`0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` of
the pool, factory + pool addresses cross-referenced with
`networks/sepolia.json` in the fabrica-land/fabrica-v3-subgraph repo.
No broadcast logs existed in this repo prior to ENG-3076; the stack
was deployed by an earlier process. Running future
`FabricaLendingPoolStackDeploy.s.sol` / `FabricaLendingPoolUpgrade.s.sol`
under `--broadcast` will write logs to `broadcast/`.)

> **Note on `broadcast/` provenance:** the carried `FabricaLendingPoolStackDeploy.s.sol`
> broadcast records the ORIGINAL stack deploy — its BorrowLogic/DepositLogic
> addresses predate the ENG-3231 library relink. The current, live post-ENG-3231
> library link addresses are in `foundry.toml`'s `[profile.sepolia]` (and the
> table above). Do NOT re-derive live link targets from the broadcast JSON.

## Hardened SimpleSignedPriceOracle Policy

ENG-3654 hardens `SimpleSignedPriceOracle` fail-closed. A pool is not
borrow-ready after only `setSigner`; operators must configure all policy
layers, then explicitly enable the collateral market.

1. Configure the signer with an ERC-1271 contract, normally the custody Safe
   or a threshold signer controlled by that Safe. EOA signer addresses are
   rejected.
2. Configure the collateral policy with the accepted currency token,
   max quote age, max quote duration, and max reference age. The contract
   enforces a hard 30 day upper bound for max reference age.
3. Configure token policies for every live token ID: hard max price,
   reference price, reference timestamp, and max deviation in basis points.
4. Enable the collateral market with the exact live token ID list. Enablement
   validates that collateral policy and every listed token policy are present
   and fresh; empty lists and partial configuration fail closed.

The deviation breaker is governance hygiene around signer drift, not an
independent market feed. The primary independent controls are the ERC-1271
threshold signer and per-token hard max prices. `price(...)` remains `view`,
so quotes have no nonce; bounded-window replay is accepted only within the
configured max quote age/duration and still remains bounded by token caps,
reference freshness, deviation limits, and Safe-controlled signing.

### Signer Rotation / Incident Response

For planned rotation, the oracle owner Safe should:

1. Call `setSigner(collateralToken, newSignerContract)`.
2. Read back `priceOracleSigner(collateralToken)`.
3. Refresh any token references that are near the 30 day SLA.
4. Exercise `price(...)` off-chain against a newly signed under-cap quote.

For signer compromise or stale policy uncertainty, disable first:

```bash
cast send <oracle> 'setCollateralEnabled(address,bool,uint256[])' \
  <collateralToken> false '[<liveTokenIds>]' --rpc-url $RPC_URL
```

Then rotate signer and refresh policies before re-enabling. Mainnet signer
rotation and market enablement are Safe-governed operator actions; agents
must prepare calldata for review only and must not sign mainnet transactions.

### Mainnet

| Contract                                | Address                                      | Notes                                          |
|-----------------------------------------|----------------------------------------------|------------------------------------------------|
| **Pool (BeaconProxy)**                  | `0x221014c0b6871f3F0d57F262ae6B5b6CD2901456` | Fabrica mainnet pool, IMPLEMENTATION_VERSION 2.15 before ENG-3686 |
| **UpgradeableBeacon**                   | `0x30E9A2082E297a2E18615224A6146f6c73F7b7A6` | `upgradeTo(newImpl)` is the upgrade lever      |
| **Beacon owner Safe**                   | `0x769586A65825B028b005176F1ebbd3B82bB07Fb0` | 2-of-3 Safe; agents do not sign mainnet ops    |
| **PoolFactory/admin proxy**             | `0x759991Bf617BAc3728983bF03Fb4d744C51F2A4F` | `owner()` is the same Safe                     |
| **Current SimpleSignedPriceOracle**     | `0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5` | Weak oracle to replace before mainnet liquidity |
| **Currency token**                      | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Mainnet USDC                                   |
| **ERC1155CollateralWrapper**            | `0x05489aC114fBaaedeE4a49B67fCc5666C951E552` | Pool constructor immutable                     |
| **EnglishAuctionCollateralLiquidator**  | `0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B` | Pool constructor immutable                     |
| **ERC20DepositTokenImplementation**     | `0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634` | Pool constructor immutable                     |
| **delegate.xyz V1 registry**            | `0x00000000000076A84feF008CDAbe6409d2FE638B` | Canonical (same on all chains)                 |
| **delegate.xyz V2 registry**            | `0x00000000000000447e69651d841bD8D104Bed493` | Canonical (same on all chains)                 |

ENG-3695 removes the ENG-3655 reserve-floor liquidation redesign and uses a
two-leg Safe packet for mainnet: upgrade the beacon to the reverted no-floor
`2.16` implementation, then repoint the pool to the ENG-3654 hardened oracle.
The new pool implementation must be linked against the newly deployed
post-revert `BorrowLogic` library and constructed with the live legacy
liquidator `0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B`. Do not deploy a new
liquidator for this cutover.

## Upgrade Pattern

Pools are deployed by `PoolFactory.createProxied(beacon, params)`, which
mints a `BeaconProxy` that delegate-calls through the beacon. Upgrading
the beacon's implementation atomically upgrades every pool created
against it. There is no per-pool upgrade; you upgrade the beacon and
every BeaconProxy sees the new code on its next call.

For ENG-3695 mainnet oracle repointing, the Safe sequence is a single Safe
transaction: a `DELEGATECALL` to `MultiSendCallOnly`
`0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761` containing two `CALL` legs:

1. `UpgradeableBeacon(0x30E9A2082E297a2E18615224A6146f6c73F7b7A6).upgradeTo(newRevertedImpl)`
2. `Pool(0x221014c0b6871f3F0d57F262ae6B5b6CD2901456).setPriceOracle(guardedOracle)`

The `newRevertedImpl` is the ENG-3695 no-floor `WeightedRateERC1155CollectionPool`
implementation. It keeps the ENG-3686 `setPriceOracle(address)` fallback
dispatcher and ENG-3654 oracle hardening while routing liquidation to the live
legacy no-reserve English auction selector. Construct it with:

- `collateralLiquidator`: `0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B`
- `delegateRegistryV1`: `0x00000000000076A84feF008CDAbe6409d2FE638B`
- `delegateRegistryV2`: `0x00000000000000447e69651d841bD8D104Bed493`
- `erc20DepositTokenImpl`: `0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634`
- `collateralWrappers`: `[0x05489aC114fBaaedeE4a49B67fCc5666C951E552]`
- `liquidationGracePeriod`: `1296000`

The packet script enforces `LiquidatorDrift` as a positive invariant: both the
live pool and the new implementation must point at the live legacy liquidator.

The hardened oracle must be deployed directly as `SimpleSignedPriceOracle`, not
behind an ERC1967 proxy. Do not use the current stack-deploy script for the
mainnet oracle unless it is first changed to stop wrapping the oracle in a
proxy. The oracle must be owned by the Fabrica Safe, have no pending ownership
transfer, use `IMPLEMENTATION_VERSION() == "1.5"` and
`DOMAIN_VERSION() == "1.2"`, and use EIP-712 domain name `"All US Land"` for
live signing continuity. Direct deploy means the deployer starts as owner;
`transferOwnership(Safe)` and Safe `acceptOwnership()` must complete before the
packet's owner/pending-owner assertions pass. The live signer is the pinned EOA
`0xC888F5e3DD4fBEB37F6e1BA6fA68c83Ab0Cf7b2c`.

Before any Safe execution, configure token policies for the complete live token
ID list, enable the market with exactly that list, and confirm the
reference-price refresh monitor runs comfortably inside the configured
`maxReferenceAge` and the contract-level `MAX_REFERENCE_AGE` of 30 days. The
canonical live FabricaToken IDs are:

`1585489599,2219685438,3170979198,4122272957,4756468797,5390664637,6341958396,7927447995`

Generate the exact mainnet Safe calldata packet without broadcasting:

```bash
export FABRICA_MAINNET_LENDING_BEACON=0x30E9A2082E297a2E18615224A6146f6c73F7b7A6
export FABRICA_MAINNET_LENDING_POOL=0x221014c0b6871f3F0d57F262ae6B5b6CD2901456
export FABRICA_MAINNET_LENDING_SAFE=0x769586A65825B028b005176F1ebbd3B82bB07Fb0
export FABRICA_MAINNET_SAFE_MULTISEND_CALL_ONLY=0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761
export FABRICA_MAINNET_LENDING_NEW_IMPL=<deployed reverted no-floor WeightedRateERC1155CollectionPool 2.16>
export FABRICA_MAINNET_LENDING_NEW_IMPL_CODEHASH=<extcodehash of deployed reverted no-floor implementation>
export FABRICA_MAINNET_GUARDED_PRICE_ORACLE=<deployed hardened SimpleSignedPriceOracle>
export FABRICA_MAINNET_GUARDED_PRICE_ORACLE_CODEHASH=<extcodehash of deployed hardened SimpleSignedPriceOracle>
export FABRICA_MAINNET_LIVE_TOKEN_IDS=1585489599,2219685438,3170979198,4122272957,4756468797,5390664637,6341958396,7927447995
export FABRICA_MAINNET_REFERENCE_REFRESH_SLA_SECONDS=<monitor SLA, e.g. 604800 for 7 days>

forge script script/FabricaLendingPoolMainnetOracleRepointPacket.s.sol:FabricaLendingPoolMainnetOracleRepointPacketScript \
  --rpc-url $MAINNET_RPC_URL
```

The implementation and guarded-oracle codehash env values are reviewed
deployment inputs, not free-form operator knobs. Include the ENG-3695 pool
implementation deployment artifact/readback, the linked `BorrowLogic` library
address, the ENG-3654 oracle deployment artifact/readback, and
`cast codehash <address>` for both deployed contracts. If the oracle deployment
model is a proxy, the packet script must be changed to validate the proxy
implementation slot and implementation codehash before any Safe packet is
emitted.

The script is view-only. It validates the canonical mainnet pool, Safe,
beacon owner, PoolFactory/admin owner, live prestate implementation and oracle,
new implementation codehash/version/constructor immutables, live collateral
token, USDC, legacy liquidator, guarded oracle direct-deploy/codehash/domain/version/owner,
pinned EOA signer, enabled collateral policy, the exact complete live token
ID list, every live token policy, and the reference-refresh SLA before printing
the MultiSendCallOnly Safe calldata. The accepted post-execution readback is:
`beacon.implementation() == newRevertedImpl`;
`pool.IMPLEMENTATION_VERSION() == "2.16"`;
`pool.collateralLiquidator() == 0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B`;
`pool.priceOracle() == guardedOracle`;
`guardedOracle.priceOracleSigner(FabricaToken) == 0xC888F5e3DD4fBEB37F6e1BA6fA68c83Ab0Cf7b2c`;
market enabled with the complete live token-ID list; monitored reference-price
refresh SLA inside `maxReferenceAge`. Pool admin, balances, and loan state must
remain unchanged.

## Sepolia Beacon Upgrade Pattern

The following sections document the historical/testnet beacon upgrade flow for
Sepolia. They are not the ENG-3695 mainnet Safe cutover procedure. Mainnet
execution is the Tim/Fede-reviewed two-leg MultiSendCallOnly packet above;
agents must not sign, broadcast, or execute it.

The upgrade is a single script (`FabricaLendingPoolUpgrade.s.sol`) that
deploys the new implementation AND calls `beacon.upgradeTo(newImpl)` in
one broadcast. Both operations are run by the beacon owner, so the
split-by-wallet pattern used for FabricaToken doesn't apply here. The
script uses `vm.deployCode` (reads the precompiled artifact) rather
than direct Solidity `new WeightedRateERC1155CollectionPool(...)` to
keep its compilation graph isolated from `FabricaLendingPoolStackDeploy.s.sol`'s
— adding a second `new` site to the project would otherwise push the
pool's runtime bytecode over EIP-170.

## Running the Upgrade

### 1. Pre-flight

```bash
# Confirm the deployer wallet still owns the beacon and that the factory
# owner agrees. If these differ from what's in this table, STOP — the
# upgrade lever is no longer in the deployer's hands.
cast call 0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E 'owner()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83 'owner()(address)' --rpc-url $SEPOLIA_RPC_URL

# Confirm the immutable args we'll bake into the new impl match the
# existing impl's. Any drift = the new impl will read wrong dependency
# addresses post-upgrade.
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'collateralLiquidator()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'delegationRegistry()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'delegationRegistryV2()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'getERC20DepositTokenImplementation()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'collateralWrappers()(address[])' --rpc-url $SEPOLIA_RPC_URL
# liquidationGracePeriod is a constructor immutable (Fabrica ENG-3113). The
# upgrade script re-supplies it via FABRICA_LENDING_LIQUIDATION_GRACE_PERIOD
# (default 1728000 = 20 days); if you forget to export it, the upgrade silently
# rebakes the grace window. Confirm the intended value against the live impl.
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'liquidationGracePeriod()(uint64)' --rpc-url $SEPOLIA_RPC_URL
```

### 2. Run the upgrade

```bash
# .env (e.g. fabrica-v3/fabrica-v3-contracts/.env) should include
# TESTNET_DEPLOYER_PRIVATE_KEY (the beacon owner), SEPOLIA_RPC_URL,
# and ETHERSCAN_API_KEY (for --verify).

export FABRICA_LENDING_BEACON=0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E
export FABRICA_LENDING_COLLATERAL_LIQUIDATOR=0xc780FEe561fc6E50493C496a53c62518971ba9EF
export FABRICA_LENDING_DELEGATE_REGISTRY_V1=0x00000000000076A84feF008CDAbe6409d2FE638B
export FABRICA_LENDING_DELEGATE_REGISTRY_V2=0x00000000000000447e69651d841bD8D104Bed493
export FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL=0x479c18dcEB406C88a0E05c86b9Ca02B6B043507B
export FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER=0xf6E3932F8b4ef957f3E361CECBF1489Ea93cb086

forge script script/FabricaLendingPoolUpgrade.s.sol:FabricaLendingPoolUpgradeScript \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $TESTNET_DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify
```

Record the printed `New WeightedRateERC1155CollectionPool:` address.
The script asserts `currentImpl != newImpl` (no-op upgrade fails fast)
and asserts `beacon.implementation() == newImpl` after the call.

### 3. Post-upgrade verification

```bash
# Beacon points at the new impl
cast call 0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E 'implementation()(address)' --rpc-url $SEPOLIA_RPC_URL

# Pool BeaconProxy now sees the new IMPLEMENTATION_VERSION (set by the
# new impl's IMPLEMENTATION_VERSION constant — bump this in the next
# vendored-tree commit if you want it visible)
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'IMPLEMENTATION_VERSION()(string)' --rpc-url $SEPOLIA_RPC_URL

# Functional check (ENG-3076): anyone can repay.
#   1. Borrow against a FabricaToken to mint a loan receipt.
#   2. Have a non-borrower address (with USDC + allowance) call repay() with that receipt.
#   3. Verify msg.sender's USDC was pulled and the borrower received their collateral.
# See FabricaLendingPoolRepaySepoliaFork.t.sol for the exact assertion shape.
```

## Upgrade History

| Date | Network | Impl Address | Notes |
|------|---------|--------------|-------|
| (initial deploy, pre-broadcast-log) | Sepolia | `0x890625c28d221B65e97D300d2BC0F305D12acDCf` | Upstream MetaStreet `WeightedRateERC1155CollectionPool` 2.15. No Fabrica modifications. |
| 2026-05-27 (ENG-3076) | Sepolia | `0xA84C15ecA620C5E4766fE0c6dd8Eaf419A838518` | Adds `Pool.depositFor(recipient, ...)` (ENG-3101) and anyone-can-repay (ENG-3076). EIP-170: 24,259 bytes (317 under). Deployed via the original FabricaLendingPoolStackDeploy.s.sol's `new WeightedRateERC1155CollectionPool(...)` site (broadcast tx `0x38efda31d7f12fe780d9a31e5b7bec0c74d15040829868de4265bbb38820bbc5`); beacon repointed via `UpgradeableBeacon.upgradeTo` shortly after. Subsequent upgrades use `FabricaLendingPoolUpgrade.s.sol` (one-shot deploy + repoint). [Etherscan-verified](https://sepolia.etherscan.io/address/0xA84C15ecA620C5E4766fE0c6dd8Eaf419A838518#code). |
| 2026-06-11 (ENG-3231) | Sepolia | `0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5` | Breaking 8-arg `borrow(address borrower, ...)` — designates the borrower-of-record/beneficial owner (repay redemption, liquidation surplus, refinance control all key off `loanReceipt.borrower`); collateral still pulled from `msg.sender`, principal still sent to `msg.sender`. The LP-dispatch layer was reclaimed from the Pool concrete into the `BorrowLogic`/`DepositLogic` external libraries to fit EIP-170: **23,628 bytes (948 under)**. New libs deployed (the `[profile.sepolia].libraries` pins above point at these): BorrowLogic `0x97bD28cd2EC4D226969221574f7EeBE301bf7557` (create tx `0xad6f6577db380f2baf5fea12bc8b85f69fb11378e18af705e58b9a86c903d104`), DepositLogic `0xcab821709338df0f718491d0f3038fbD6a16CfbE` (create tx `0xc05a58f5406f90eeaf6cc7c42e6fadb423b5d4fb70b52655ac4a7b6b103c9c59`); LiquidityLogic + ERC20DepositTokenFactory unchanged. Impl deployed + beacon repointed via `FabricaLendingPoolUpgrade.s.sol` (impl create tx `0x91c043b3312b83968b2f082f4a55334a287c32ccfddfe091ff5a0bd18ca5fe52`); beacon `0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E` repointed from prior impl `0x09b91D006ecAC914e84e34C82f8266118Aaee8ED` via `UpgradeableBeacon.upgradeTo` (tx `0x3c59e896ea6d9e6984c241ed58759144b9c569acd0cf5b1b51b7255e21d7cbef`). Soil ships the lockstep `supportsBorrowerParam` per-pool flag (soil #1100). |

### Live verification (Sepolia, 2026-05-27)

Functional smoke against the LIVE upgraded pool — third-party repay
exercised the new code path end-to-end with no config change to Soil
or the API (pool address `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`
is the unchanged BeaconProxy).

| Assertion | Before tx | After tx | ✓ |
|---|---|---|---|
| Loan status | 1 (Active) | 2 (Repaid) | ✓ |
| Staging-API-wallet USDC | 17,127,900 | 16,126,156 | -1,001,744 raw USDC pulled from third party (NOT the borrower) |
| Original borrower USDC | 5,999,554 | 5,999,554 | unchanged — borrower paid nothing |
| Borrower holds collateral | 0 | 1 | collateral returned to original borrower |
| Pool holds collateral | 1 | 0 | pool released collateral |

- Loan receipt hash: `0x7c60c27cf5176aedcd005825842f4a2c84ae4e33e45b6b6cfd0c5129ce957934`
- Original borrower: `0xadd5a1b8f83cad37120dc0c80af29cd42406e7a6`
- Third-party caller (the staging API `mintingWallet`): `0x5Cf573087BB00d56b457C108F373a3ac4984e28b`
- Collateral: FabricaToken id `6916740955630765930`
- Repay tx: [`0x90e99cfddfd2ec8ec7afabb8084d2f943a82a944b4f4a07b74bd6183456ed59a`](https://sepolia.etherscan.io/tx/0x90e99cfddfd2ec8ec7afabb8084d2f943a82a944b4f4a07b74bd6183456ed59a)

## ENG-3519 WP-B — Oracle launch path & Sepolia mode report

### Sepolia deployment mode (item 1)

Live Sepolia pool `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` is a **BeaconProxy**
created via `PoolFactory.createProxied(beacon, params)` against beacon
`0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E`. It is **not** an EIP-1167 clone
from `create()`.

### setPriceOracle (item 2) — size-safe design

IMPLEMENTATION_VERSION `2.16` adds `setPriceOracle(address)` (selector
`0x530e784f`) via a size-constrained `fallback` on
`WeightedRateERC1155CollectionPool`. Caller must be pool `admin()` or
`Ownable(admin).owner()`. Candidate must have contract code.

**On-chain 48h timelock does not fit under EIP-170** with the existing Fabrica
pool deltas (measured ~1.8KB over limit with schedule/execute). Operational
delay: queue `setPriceOracle` through the **Safe transaction delay module**
(48–72h) on the admin/Safe path. Documented here as the design-review choice
for WP-B; revisit a leaner on-chain delay only if a future size budget opens.

### Launch path scripts (item 3) — **no agent broadcasts**

- `script/FabricaLendingPoolCreateWithAggregator.s.sol` — createProxied with aggregator
- `script/FabricaLendingPoolScheduleOracle.s.sol` — setPriceOracle calldata helper

Real chain broadcasts are Tim/Fede-gated. Agents use dry-run + throwaway anvil only.

### Acceptance (item 5)

- Empty `oracleContext` is valid for aggregator-priced `price()` (unit + anvil).
- Dead-heartbeat aggregator fail-closed reverts `price()` → borrow cannot originate.
