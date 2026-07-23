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
| **EnglishAuctionCollateralLiquidator**  | `0xc780FEe561fc6E50493C496a53c62518971ba9EF` | Current pre-ENG-3655 liquidator; ENG-3655 cutover must deploy and use a new reserve-aware liquidator proxy |
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

ENG-3686 adds a size-constrained `setPriceOracle(address)` selector shim to
`WeightedRateERC1155CollectionPool` so the existing BeaconProxy can be
upgraded and then repointed to the hardened `SimpleSignedPriceOracle`
deployed from this fork. The pool is close to EIP-170, so the shim lives in
`fallback()` and accepts only the canonical `setPriceOracle(address)` selector
with 36-byte calldata; empty calldata and every other selector revert
`InvalidParameters()`. The mainnet operation is a Safe packet reviewed by
Tim/Fede before execution. Engineers may deploy inert
implementations and produce calldata, but must not sign, broadcast, or execute
mainnet Safe operations.

Exact-head size evidence must stay attached to the PR because this pool is at
the EIP-170 edge. On the ENG-3686 final board head, `script/check-pool-size.sh`
reported `WeightedRateERC1155CollectionPool runtime=24260B (EIP-170 limit
24576B, margin 316B)`. The full size command,
`forge clean && forge build --sizes --json`, reports the
`WeightedRateERC1155CollectionPool` target under the EIP-170 limit; its
repository-wide nonzero exit is from pre-existing, unrelated weighted-rate
variants that remain oversized and are not the ENG-3686 implementation target.

## Upgrade Pattern

Pools are deployed by `PoolFactory.createProxied(beacon, params)`, which
mints a `BeaconProxy` that delegate-calls through the beacon. Upgrading
the beacon's implementation atomically upgrades every pool created
against it. There is no per-pool upgrade; you upgrade the beacon and
every BeaconProxy sees the new code on its next call.

For ENG-3686 mainnet oracle repointing, the Safe sequence is two calls:

1. `UpgradeableBeacon.upgradeTo(newImpl)`
2. `WeightedRateERC1155CollectionPool.setPriceOracle(guardedOracle)`

The `setPriceOracle(address)` selector shim is callable only by the pool admin
itself or `Ownable(pool.admin()).owner()`. For the Fabrica mainnet pool this
makes the PoolFactory owner Safe the operational repoint authority. Any future
factory owner change is therefore a pool oracle-security event and must be
reviewed with the same weight as beacon ownership. If the admin `owner()`
lookup fails or returns any other caller, the operation reverts with
`InvalidPriceOracleUpdater()`. Candidate oracle addresses must be nonzero,
must contain code, must differ from the current oracle, and must respond to a
`price(address,address,uint256[],uint256[],bytes)` staticcall with either a
32-byte return value or a typed revert from the candidate implementation. The
oracle write uses the existing ERC-7201
`externalPriceOracle.priceOracleStorage` slot and emits
`PriceOracleUpdated(previousOracle, newOracle, caller)`.

Generate the exact mainnet Safe calldata packet without broadcasting:

```bash
export FABRICA_MAINNET_LENDING_BEACON=0x30E9A2082E297a2E18615224A6146f6c73F7b7A6
export FABRICA_MAINNET_LENDING_POOL=0x221014c0b6871f3F0d57F262ae6B5b6CD2901456
export FABRICA_MAINNET_LENDING_SAFE=0x769586A65825B028b005176F1ebbd3B82bB07Fb0
export FABRICA_MAINNET_SAFE_MULTISEND_CALL_ONLY=0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761
export FABRICA_MAINNET_LENDING_NEW_IMPL=<deployed WeightedRateERC1155CollectionPool 2.16 implementation>
export FABRICA_MAINNET_GUARDED_PRICE_ORACLE=<deployed hardened SimpleSignedPriceOracle>

forge script script/FabricaLendingPoolMainnetOracleRepointPacket.s.sol:FabricaLendingPoolMainnetOracleRepointPacketScript \
  --rpc-url $MAINNET_RPC_URL
```

The script is view-only. It validates the env target addresses against the
canonical mainnet beacon, pool, Safe, and PoolFactory/admin proxy listed above;
then it validates beacon owner, factory owner, the canonical Safe
MultiSendCallOnly address, nonzero code at both target addresses, the new
implementation name/version, immutable dependency parity with the live pool,
hardened oracle version/domain/owner, and non-no-op prestate before printing
both individual calldata legs and the exact
MultiSendCallOnly `multiSend(bytes)` calldata wrapping:

1. `UpgradeableBeacon.upgradeTo(newImpl)`
2. `WeightedRateERC1155CollectionPool.setPriceOracle(hardenedOracle)`

Operators should execute the two calls atomically as a Safe `DELEGATECALL` to
the canonical MultiSendCallOnly contract. A normal Safe `CALL` to
MultiSendCallOnly is wrong: subcalls would originate from the helper contract,
not the Safe, and owner/updater checks would fail. An upgrade-only partial
resting state is not corrupting: the pool still points at the old oracle and
remains in the pre-cutover risk posture. It is nevertheless incomplete and must
not be treated as a finished mainnet-liquidity control. The accepted
post-batch readback is:
`beacon.implementation() == newImpl`,
`pool.IMPLEMENTATION_VERSION() == "2.16"`, and
`pool.priceOracle() == hardenedOracle`, with pool admin and balances/loan
state unchanged.

## Sepolia Beacon Upgrade Pattern

The following sections document the historical/testnet beacon upgrade flow for
Sepolia. They are not the ENG-3686 mainnet Safe cutover procedure. Mainnet
execution for ENG-3686 is the Tim/Fede-reviewed Safe MultiSend packet above;
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

# Confirm the immutable args we'll bake into the new impl. ENG-3655
# intentionally replaces collateralLiquidator with a newly deployed
# reserve-aware EnglishAuctionCollateralLiquidator proxy configured for
# the ERC1155 wrapper. Reusing the pre-ENG-3655 liquidator will make
# reserve-aware liquidations fail after beacon cutover.
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

# ENG-3655 cutover gate: STOP unless operations has verified zero active
# liquidations/auctions for every pool on this beacon. Old-liquidator
# auctions can no longer finalize after the pool immutable points at the
# new reserve-aware liquidator.
```

### 2. Run the upgrade

```bash
# .env (e.g. fabrica-v3/fabrica-v3-contracts/.env) should include
# TESTNET_DEPLOYER_PRIVATE_KEY (the beacon owner), SEPOLIA_RPC_URL,
# and ETHERSCAN_API_KEY (for --verify).

export FABRICA_LENDING_BEACON=0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E
# ENG-3655: replace this with the newly deployed reserve-aware
# EnglishAuctionCollateralLiquidator proxy, not the pre-ENG-3655 address
# listed in the network table.
export FABRICA_LENDING_COLLATERAL_LIQUIDATOR=<NEW_RESERVE_AWARE_LIQUIDATOR_PROXY>
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
