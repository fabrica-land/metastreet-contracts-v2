# ENG-3519 — Sepolia launch pool: deployment report, acceptance evidence, tick policy

Lane: `pardulas` · Date: 2026-08-14 · Branch: `pardulas/eng-3519-sepolia-launch-pool`

Spec read before any work: **fabrica-v3-contracts PR #34** (WP-A,
`062f049`, merged 2026-07-29) and **metastreet-contracts-v2 PR #8** (WP-B,
`6fbbd53`, merged 2026-07-29).

---

## 0. Headline: the launch pool was NOT broadcast to Sepolia, deliberately

This lane was chartered with "Sepolia state changes are authorized." The merged
WP-B artifacts encode a **narrower, reviewed gate** in three independent places:

| # | Location | Text |
|---|----------|------|
| 1 | `script/FabricaLendingPoolCreateWithAggregator.s.sol` NatSpec | "**No on-chain deploys from agents.** Tim/Fede-gated operators may broadcast. Agents: forge script without `--broadcast` for dry-run; anvil for FV." |
| 2 | `LENDING-POOL-RUNBOOK.md` § WP-B item 3 | "Real chain broadcasts are Tim/Fede-gated. Agents use dry-run + throwaway anvil only." |
| 3 | PR #8 body, § Standing | "SOURCE + tests + scripts only — **no on-chain deploys**" |

The conflict was raised rather than resolved unilaterally, and the ruling was
that **the specific gate beats the general grant** — documentation of a crossed
gate is not authorization to cross it. So this report delivers, in place of a
broadcast: a script dry-run, a complete acceptance rehearsal on a Sepolia fork,
and a broadcast-ready package (§6) that an authorized operator can execute
directly.

**Every Sepolia interaction in this report is read-only** (`eth_call`,
`eth_getStorageAt`, `eth_getCode`, `eth_getLogs`) or executed against a local
fork. No transaction was signed or sent to any live chain.

---

## 1. Item 1 — deployment mode of the live Sepolia pool: **BeaconProxy**

**Answer: `createProxied` (BeaconProxy + UpgradeableBeacon). It is NOT an
EIP-1167 clone, so future oracle swaps on THIS pool are beacon upgrades, not
redeploys.**

Evidence, pool `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`:

```text
$ cast rpc eth_getStorageAt 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B \
    0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 latest
"0x000000000000000000000000e1b74cbf78a693e6289dc1c983d8bc2e5097139e"
```

That slot is canonical ERC-1967 `eip1967.proxy.beacon`
(`keccak256("eip1967.proxy.beacon") - 1`, verified by recomputation), and it
holds beacon `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e`.

Three independent confirmations:

1. **Slot occupancy** — an EIP-1167 clone has no storage and no beacon slot.
2. **Runtime shape** — `cast code` returns **451 bytes** whose body loads that
   slot, `staticcall`s `implementation()` (selector `0x5c60da1b`) on it, then
   `delegatecall`s the result. An EIP-1167 clone is exactly **45 bytes** with
   the implementation address inlined and no `implementation()` call.
3. **Factory registry** — `PoolFactory.getPoolImplementations()` returns
   `[0xe1B74Cbf…139E]`: the beacon itself is the only allowed "implementation",
   which is only meaningful on the `createProxied` path.

```text
$ cast call 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e "implementation()(address)"
0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5
$ cast call 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e "owner()(address)"
0xBF03076547a99857b796717faF4034dea94569dF
```

**Consequence:** one `beacon.upgradeTo(newImpl)` by the beacon owner atomically
upgrades every pool created against this beacon. There is no per-pool upgrade.

---

## 2. Item 2 — merged timelock value for `setPriceOracle`

**Reported, not chosen. The merged value is: there is no on-chain timelock.**

| Property | Merged reality |
|----------|----------------|
| On-chain enforced delay | **None — zero.** `_setPriceOracle` applies immediately. |
| Authorization | pool `admin()`, or `Ownable(admin).owner()` |
| Candidate validation | `newOracle != 0` and `newOracle.code.length != 0`; also rejects unchanged |
| Delay mechanism as merged | **Operational only** — Safe delay module |
| Proposed window | **48–72h**, queued on the Safe |
| On-chain scheduler | **Rejected** — EIP-170 budget (667B margin) |
| Sign-off | Tim/Fede, pre-deploy — **still open** |

Source: `contracts/oracle/ExternalPriceOracle.sol` (`_setPriceOracle` has no
time check), the WP-B knobs table in `LENDING-POOL-RUNBOOK.md`, and PR #8's
"SECURITY POSTURE" section. The ED disposition recorded 2026-07-29 accepted the
size-safe setter plus an operational Safe delay.

⚠️ **Read this as a reviewer:** anyone auditing the Solidity alone will not find
a 48h/72h lock, because there isn't one. The delay property lives entirely in
the operational control plane. If the Safe is not configured with a delay
module before launch, the repoint is effectively instantaneous for whoever holds
the admin owner key.

### 2a. Gap found: `setPriceOracle` exists nowhere on live Sepolia

```text
$ cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B "IMPLEMENTATION_VERSION()(string)"
"2.15"
```

`setPriceOracle` shipped in **2.16**. The live beacon still points at
`0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5` = **2.15**. So WP-B's setter is
merged in source but **not deployed**. A beacon upgrade is a prerequisite for
any *repoint* capability — see §6, step 3. It is **not** a prerequisite for the
launch pool itself, because the aggregator is wired at `initialize()`, which
2.15 already supports (proven in §4).

---

## 3. Item 3 — launch pool deployment (dry-run + fork rehearsal)

### 3a. Prerequisite gap: nothing in the oracle chain is deployed

Neither **FabricaAttributeOracle** (ENG-3518 fact store) nor
**FabricaOracleAggregator** (WP-A) has a deployed Sepolia address. Searched:
every repo runbook and `*.md`, `fabrica-v3-api/config/*.json`,
`soil-app/config`, `fabrica-v3-subgraph/networks/*.json`, and
`fabrica-v3-contracts/broadcast/`. No address anywhere.

The launch is therefore a **four-step sequence**, not one transaction (§6).

### 3b. Script dry-run — intended vs. deployed parameters

`FABRICA_LENDING_DRY_RUN=true forge script script/FabricaLendingPoolCreateWithAggregator.s.sol --rpc-url sepolia`

```text
  === ENG-3519 WP-B launch path (createProxied -> aggregator) ===
  Factory:      0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83
  Beacon:       0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e
  Aggregator:   0x0000000000000000000000000000000000000a11   <-- PLACEHOLDER
  Currency:     0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
  Collateral:   0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
  Mode:         DRY_RUN (no broadcast)
  Params len:   800
  Dry-run complete - operator broadcasts with FABRICA_LENDING_DRY_RUN=false
```

The aggregator address is a **placeholder** precisely because of §3a — it is the
one parameter that cannot be filled until step 2 of §6 runs.

**Initializer parameters — intended vs. what the dry-run encoded.** This is the
literal review gate the ticket asks for:

| Param | Intended | Encoded by script | Match |
|-------|----------|-------------------|-------|
| `collateralTokens[0]` | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` (FabricaToken) | same | ✅ |
| `currencyToken` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (USDC Sepolia) | same | ✅ |
| `priceOracle` | renounced `FabricaOracleAggregator` | **placeholder — not yet deployed** | ⛔ blocked on §6 step 2 |
| `durations[0..7]` | `62208000, 31104000, 23328000, 15552000, 10368000, 7776000, 5184000, 2592000` | same (strictly descending) | ✅ |
| `rates[0..7]` | `1585489599, 2219685438, 3170979198, 4122272957, 4756468797, 5390664637, 6341958396, 7927447995` | same (~5/7/10/13/15/17/20/25% APR, per-second 1e18) | ✅ |
| ABI encoding | `abi.encode(address[],address,address,uint64[],uint64[])` | 800 bytes | ✅ |

Note the launch `durations`/`rates` are the **mainnet tiers**, and they differ
from the live Sepolia pool's current set only in that the live pool carries the
same eight values — confirmed by `cast call … durations()/rates()`.

### 3c. EIP-170 gate (authoritative command for this fork)

```text
$ bash script/check-pool-size.sh
OK:   WeightedRateERC1155CollectionPool runtime=23909B  (EIP-170 limit 24576B, margin 667B)
```

Independently reproduces PR #8's claim (23909B / 667B margin) byte-for-byte.

---

## 4. Acceptance evidence

Delivered as a **Sepolia fork rehearsal**, not a live broadcast (§0).

New suite: `fabrica-v3-contracts/test/Eng3519LaunchPoolSepoliaFork.t.sol`
(branch `pardulas/eng-3519-sepolia-launch-pool` in that repo).

**Why a new suite was needed.** WP-B's `FabricaLendingPoolOracleTimelock.t.sol`
proves its wiring against a `MockAggregatorOracle` stub and asserts at the
`pool.price(...)` level. It never deploys the real aggregator, never touches the
live beacon, and **never originates a loan**. The ticket states acceptance at
the *borrow* level. This suite closes that gap: real `FabricaOracleAggregator`
(post-`renounceAggregator()`), real `FabricaAttributeOracle` really seeded, the
**live** `PoolFactory` + `UpgradeableBeacon` (so calls dispatch through deployed
bytecode), and a real `borrow()`.

```text
$ forge test --match-contract Eng3519LaunchPoolSepoliaForkTest \
             --fork-url $SEPOLIA_RPC_URL -vv

Ran 5 tests for test/Eng3519LaunchPoolSepoliaFork.t.sol:Eng3519LaunchPoolSepoliaForkTest
[PASS] test_acceptanceA_originatesLoanWithEmptyOracleContext() (gas: 467049)
Logs:
  acceptance(a): aggregator.price with empty context = 90000000000
  acceptance(a): quoted repayment = 1004109590
  acceptance(a): principal  = 1000000000
  acceptance(a): repayment  = 1004109590

[PASS] test_acceptanceB_deadHeartbeatRefusesNewBorrows() (gas: 139930)
Logs:
  acceptance(b): borrow refused with CheckFailed(heartbeat) after maxSilence = 86400

[PASS] test_aggregatorUsesMergedDesignReviewDefaults() (gas: 8211)
[PASS] test_item1_livePoolIsBeaconProxyNotClone() (gas: 7704)
Logs:
  item 1: live pool runtime bytes = 451
  item 1: beacon from ERC-1967 slot = 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e

[PASS] test_item3_launchPoolIsBeaconProxyWiredToAggregator() (gas: 55498)
Logs:
  item 3: launch pool  = 0xc423481120be703757D997b2835bc7709121f235
  item 3: priceOracle  = 0x2e234DAe75C793f67A35089C9d99245E1C58470b
  item 3: impl version = 2.15

Suite result: ok. 5 passed; 0 failed; 0 skipped
```

(Fork addresses are fork-local, not live Sepolia deployments.)

### (a) Launch pool originates a loan priced by the on-chain oracle, empty `oracleContext` ✅

- Pool created by `PoolFactory.createProxied(beacon, params)` against the **live
  beacon**; its ERC-1967 beacon slot is asserted equal to `0xe1B74Cbf…139E`, and
  `priceOracle()` equals the renounced aggregator — set at `initialize()`.
- `aggregator.price(FabricaToken, USDC, [tokenId], [1], "")` → **90000000000**
  (= 90,000 USDC), i.e. the **MIN** of the two live sources (90,000 and 100,000).
- `borrow(..., options: "")` succeeded: **principal 1000000000** (1,000 USDC)
  out, **repayment 1004109590**, `LoanOriginated` emitted by the launch pool,
  collateral escrowed (borrower ERC-1155 balance 1 → 0).
- `options = ""` is exactly what makes `oracleContext` empty:
  `BorrowLogic._getOptionsData(options, BorrowOptions.OracleContext)` returns
  empty bytes. The aggregator ignores the parameter entirely and reads only
  on-chain facts.
- Collateral is a **real** Sepolia FabricaToken id (`3561233430243998108`) held
  by a real address, not a mock.

### (b) Dead-heartbeat oracle pool refuses new borrows ✅

- Same aggregator; time warped past the fact store's `maxSilence` (86400s).
- `isHeartbeatFresh(validatorId)` flips true → false.
- `aggregator.price(...)` reverts `CheckFailed(CHECK_HEARTBEAT)`.
- `borrow(...)` reverts with the **exact same** error selector+arg — asserted via
  `vm.expectRevert(abi.encodeWithSelector(CheckFailed.selector, CHECK_HEARTBEAT))`,
  so this is a specific fail-closed proof, not "it reverted for some reason."
- `maxRepayment` is passed as a plain in-range value so the oracle check is the
  only thing that can revert it.

### (c) Tick-policy report delivered ✅ — see §5.

---

## 5. Item 4 — tick policy (measured split + recommendation)

### Mechanism (`contracts/Tick.sol`, `decode`)

```solidity
limitType = tick == type(uint128).max ? LimitType.Absolute : LimitType(tick & TICK_LIMIT_TYPE_MASK);
limit     = limitType == LimitType.Ratio ? Math.mulDiv(oraclePrice, limit, BASIS_POINTS_SCALE) : limit;
```

`enum LimitType { Absolute, Ratio }` — Absolute = 0, Ratio = 1.

- **Absolute** — `limit` is a fixed currency depth. Capacity is
  **price-independent**: an inflated oracle does not expand how many dollars
  this node will fund.
- **Ratio** — `limit = oraclePrice * bps / 10_000`. Capacity **scales linearly
  with oracle price**. Overpriced oracle ⇒ strictly more dollars drawn.

### Measured split — live pool `0x6C56…c0B`, re-read 2026-08-14

Source: `liquidityNodes(0, type(uint128).max)`, decoded with the shift/mask
constants above. Head sentinel (tick 0, value 0) excluded.

| Tick (raw) | Type | Limit (decoded) | Dur idx | Rate idx | Node value (18dp) |
|------------|------|-----------------|---------|----------|-------------------|
| `1280189` | **Ratio** | 5000 bps = **50% LTV** | 5 | 7 | 186.772808 |
| `256000000000000000036` | Absolute | 1e18 (**$1**) | 1 | 1 | 0.200000 |
| `256000000000000000000` | Absolute | 1e18 (**$1**) | 0 | 0 | 25.601734 |
| `256000000000000000000000` | Absolute | 1e21 (**$1,000**) | 0 | 0 | 5.000276 |

| Class | Value (18dp) | Share |
|-------|--------------|-------|
| **Ratio** | 186.772808 | **85.84%** |
| **Absolute** | 30.802010 | **14.16%** |
| TOTAL | 217.574818 | 100.00% |

This is an **independent re-measurement** taken 2026-08-14 and it reproduces the
2026-07-29 WP-C figures (~85.8% / ~14.2%). The split has not moved.

Currency is USDC (6dp) but pool-internal values are normalized to 18dp; the
percentage split is unaffected by the scale.

### Recommendation (a recommendation — the decision is Tim/Fede's)

**Steer land-collateral pools to Absolute-limit ticks, and treat the oracle band
as defense-in-depth rather than the primary loss cap.**

| Knob | Recommendation | Why |
|------|----------------|-----|
| Tick limit type for land | **Absolute primary** | Price-independent stack depth: an oracle error cannot enlarge the draw |
| Ratio ticks | Optional senior stretch only, ≤30–40% LTV | Keeps price-scaling exposure to a thin slice |
| Target TVL mix | **≥80% Absolute by value** | Inverts today's 85.84% Ratio concentration |
| Max duration (land) | Short, until continuous monitoring exists | Oracle is origination-only; long loans rot un-monitored |
| Absolute ladder $ | Product-defined | Today's Sepolia $1 / $1,000 rungs are test toys, not a ladder |

**The load-bearing argument:** the oracle band (WP-A's MIN + temporal floor +
eligibility) constrains *the price*. Ratio ticks convert any residual price
error directly into *dollars lent*. Absolute ticks break that transmission
entirely — they cap the draw regardless of what the oracle says. Given the live
pool is **85.84% Ratio by value**, the primary loss cap is currently the weakest
of the two available mechanisms, and fixing that requires **zero new code** —
only which ticks LPs are steered into.

Caveat worth stating plainly: borrowers choose their tick list at borrow time
and there is no guaranteed attachment at low ticks, so this is a
liquidity-composition lever, not an enforcement mechanism. Enforcing it would
need a collateral filter or tick allowlist — new code, out of scope here.

Full prior treatment (unchanged, still accurate):
`fabrica-v3/wrap-ups/artifacts/ENG-3519-wpc-tick-policy.md`.

---

## 6. Broadcast-ready package (Tim/Fede-gated)

Four steps. Steps 1–2 are in **fabrica-v3-contracts**; steps 3–4 in **this
repo**. All are gated; none has been executed.

Prereqs: `.env` with `SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`, and the deployer
key. **Steps 3–4 require the beacon/factory owner**
`0xBF03076547a99857b796717faF4034dea94569dF` (`TESTNET_DEPLOYER_PRIVATE_KEY`).
Steps 1–2 may use any funded key. Est. gas: well under 0.1 Sepolia ETH total;
step 4 dominates (BeaconProxy + `initialize`).

### Step 1 — deploy + seed FabricaAttributeOracle (fact store)

No deploy script exists for it yet — it needs writing, or a `cast send` sequence.
Constructor: `(address owner_, KnobConfig knobs_)`; `defaultKnobs()` supplies the
merged start values (`maxUpBps 1500`, `maxDownBps 5000`,
`maxFirstPriceUsdc6 50_000_000e6`, `maxSilence 24h`, `minWriteInterval 1h`,
`registrySeasonDelay 1 day`, `valueCeilingUsdc6 50_000_000e6`,
`historyDepth 48`). Then, as owner:
`setPricePublisher`, `setSourceEnabled` (≥2 sources), `register(validatorId, tokenId)`.
Then, as publisher: `writePrice` for ≥2 sources (each write also touches the
heartbeat). **Registry seasoning is 1 day** — the pool cannot price a token
until it has seasoned, so this step must land ≥24h before step 4 is useful.

### Step 2 — deploy + configure + renounce FabricaOracleAggregator

Constructor `(owner_, factStore_, usdc_, validatorId_, sourceIds_, seasoningWindow_, maxJumpBps_, maxDispersionBps_, minLiveSources_)`.
Merged start proposals from `designReviewDefaults()`:

| Param | Merged value | Status |
|-------|--------------|--------|
| `seasoningWindow_` | `86400` (24h) | start proposal |
| `maxJumpBps_` | `5000` | ⚠️ **"TBD" in the WP-A design-review table** |
| `maxDispersionBps_` | `20000` | ⚠️ **"TBD" in the WP-A design-review table** |
| `minLiveSources_` | `2` | start proposal |

⚠️ **Open decision, not mine to make:** WP-A's NatSpec records `maxJumpBps` and
`maxDispersionBps` as **TBD pending Tim/Fede**, even though the code carries
concrete start proposals. Confirm both before deploying — the aggregator is
**immutable after renounce**, so a wrong value here means a redeploy plus a
`setPriceOracle` repoint, not a config change.

Then call **`renounceAggregator()`** — one-way, freezes all knobs forever. Do it
*before* step 4 so the pool is wired to an already-frozen oracle.

### Step 3 — beacon upgrade 2.15 → 2.16 (needed only for repoint capability)

```bash
FOUNDRY_PROFILE=sepolia forge script script/FabricaLendingPoolUpgrade.s.sol \
  --rpc-url sepolia --private-key $TESTNET_DEPLOYER_PRIVATE_KEY --broadcast --verify
```

Run as beacon owner. ⚠️ Export `FABRICA_LENDING_LIQUIDATION_GRACE_PERIOD`
(default `1728000` = 20 days) or the upgrade silently rebakes the grace window.

⚠️ **Shared-chain blast radius:** this beacon backs the **live** pool
`0x6C56…c0B` and every other pool created against it, across all API stages
pointed at Sepolia. Upgrading it is not scoped to the new launch pool.
Verify after: `cast call <beacon> "implementation()(address)"` and
`cast call <pool> "IMPLEMENTATION_VERSION()(string)"` → `"2.16"`.

**Ordering choice for Tim/Fede:** step 3 can also run *after* step 4. The launch
pool gets its aggregator at `initialize()`, which 2.15 already supports (proven
in §4 — the fork rehearsal ran entirely against the live 2.15 implementation).
Deferring step 3 gives a shorter first hop and keeps the live pool untouched
until the launch pool is validated. Step 3 is required only before you need
`setPriceOracle`.

### Step 4 — create the launch pool

```bash
export FABRICA_LENDING_FACTORY=0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83
export FABRICA_LENDING_BEACON=0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e
export FABRICA_LENDING_AGGREGATOR=<step-2 address>
export FABRICA_LENDING_CURRENCY_TOKEN=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
export FABRICA_LENDING_COLLATERAL_TOKEN=0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
export FABRICA_LENDING_DRY_RUN=false
forge script script/FabricaLendingPoolCreateWithAggregator.s.sol \
  --rpc-url sepolia --private-key $TESTNET_DEPLOYER_PRIVATE_KEY --broadcast
```

`createProxied` is permissionless (no `onlyOwner`), but the beacon must be in
`_allowedImplementations` — it already is, and it is the only entry.

Post-deploy verification:

```bash
cast call <pool> "priceOracle()(address)"            # == step-2 aggregator
cast call <pool> "currencyToken()(address)"          # == USDC
cast call <pool> "admin()(address)"                  # == factory
cast rpc eth_getStorageAt <pool> \
  0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 latest  # == beacon
```

Then record the address in `LENDING-POOL-RUNBOOK.md` § Network Addresses, commit
`broadcast/`, and update consumers per `fabrica-v3-contracts/DEPLOYMENT.md`
("Post-deploy: capture the address").

### Post-launch, before any real liquidity

1. Configure the **Safe delay module** (48–72h) — without it the repoint delay
   from §2 does not exist in any form.
2. Steer initial LP deposits into **Absolute** ticks per §5.

---

## 7. Open items owned by Tim/Fede, not by this lane

| # | Item | Why it is not mine |
|---|------|--------------------|
| 1 | Authorize the Sepolia broadcast (or run §6 as operator) | Gate is explicit and reviewed |
| 2 | Confirm `maxJumpBps` / `maxDispersionBps` | Marked TBD in WP-A; immutable after renounce |
| 3 | Confirm Safe delay window (48–72h) + configure the module | Operational control plane |
| 4 | Accept/adjust the tick recommendation in §5 | Product/risk decision |
| 5 | Decide step 3 vs step 4 ordering | Blast-radius tradeoff on a shared beacon |

---

## 8. Provenance of every claim

| Claim | How verified |
|-------|--------------|
| BeaconProxy, not clone | `eth_getStorageAt` beacon slot + 451-byte runtime disassembly + factory registry |
| Beacon impl is 2.15 | `cast call` on live pool + `beacon.implementation()` |
| No on-chain timelock | Read `_setPriceOracle` source; no time check present |
| Aggregator/fact store undeployed | Searched all runbooks, api/soil/subgraph configs, `broadcast/` |
| Tick split 85.84 / 14.16 | `liquidityNodes()` live read, decoded with `Tick.sol` constants |
| EIP-170 23909B / 667B | `bash script/check-pool-size.sh` re-run locally |
| Acceptance (a) and (b) | `forge test --fork-url $SEPOLIA_RPC_URL`, 5/5 pass |
| Dry-run params | `forge script` without `--broadcast`, output pasted verbatim |
