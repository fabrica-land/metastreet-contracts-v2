# Fabrica Lending Pool Contracts

A Fabrica fork of [`metastreet-labs/metastreet-contracts-v2`](https://github.com/metastreet-labs/metastreet-contracts-v2).

Fabrica operates a lending pool derived from MetaStreet's v2 pool. This repository
is a **fork** of the upstream MetaStreet contracts so that Fabrica's changes are
recorded as discrete commits on top of the exact upstream source, and the full
history remains auditable back through MetaStreet's own commit history.

## Lineage

- **Fork base:** upstream commit `8ed467d272a2cee35751e60851fa1b830e2fe018`
  (`metastreet-labs/metastreet-contracts-v2`, 2025-02-12).
- Every Fabrica change sits as a commit **on top of** that base, in the upstream
  file layout, so `git blame contracts/*.sol` traces each line to either MetaStreet
  or the specific Fabrica commit that changed it.
- Upstream `@author MetaStreet Labs` attributions and the BUSL-1.1 license are
  preserved verbatim.

## Fabrica behavioral changes on top of upstream

| Ticket | Change |
|--------|--------|
| ENG-3101 | `Pool.depositFor(recipient, …)` — credit LP shares to a recipient distinct from the currency payer (fiat on-ramp support). |
| ENG-3076 | Allow anyone to repay an existing loan. |
| ENG-3113 | Constructor-parameterized liquidation grace period (propagated across all pool configurations). |
| ENG-3231 | `borrow(borrower)` designated-borrower support; reclaim EIP-170 headroom into libraries. |

## Toolchain

This fork uses **Foundry**; upstream's hardhat/TypeScript build, test, and deploy
framework has been replaced.

Build:

```
forge build
```

Test:

```
forge test
```

Fork tests (Sepolia / mainnet) gate on an RPC URL and self-skip without one; run
them with `--fork-url $RPC_URL`.

### Compilation notes

- Solc 0.8.25, `via_ir = true`. Base contracts compile at `optimizer_runs = 800`
  (mirroring upstream's hardhat config) to resolve "stack too deep".
- `WeightedRateERC1155CollectionPool` — the configuration Fabrica deploys — is grown
  by the behavioral deltas past EIP-170's 24576-byte runtime limit at high optimizer
  runs, so it alone compiles at `optimizer_runs = 1` (see `foundry.toml`).
- OpenZeppelin contracts are pinned at v4.9.6 (upstream's `package.json` pin).

## Deployment

Foundry deploy scripts live in [`script/`](script/):

- [`FabricaLendingPoolStackDeploy.s.sol`](script/FabricaLendingPoolStackDeploy.s.sol) — one-shot deploy of the reusable pool infra.
- [`FabricaLendingPoolCreate.s.sol`](script/FabricaLendingPoolCreate.s.sol) — instantiate a pool against existing infra.
- [`FabricaLendingPoolUpgrade.s.sol`](script/FabricaLendingPoolUpgrade.s.sol) — upgrade an existing pool implementation.

Live per-chain deployment addresses (mainnet/sepolia), the beacon-based upgrade
flow, and deploy-transaction provenance are in
[`LENDING-POOL-RUNBOOK.md`](LENDING-POOL-RUNBOOK.md). The per-chain external
library link addresses are pinned in `foundry.toml`'s `[profile.mainnet]` /
`[profile.sepolia]` (select with `FOUNDRY_PROFILE=<chain>`).

## File structure

- [`contracts/`](contracts/) — pool smart contracts (upstream layout; see per-file
  `@author` tags for MetaStreet-authored source).
- [`test/`](test/) — Fabrica Foundry test suite (unit + Sepolia/mainnet fork tests).
- [`script/`](script/) — Fabrica Foundry deploy scripts.
- [`lib/`](lib/) — Foundry dependencies (forge-std, OpenZeppelin v4.9.6).
- [`docs/`](docs/) — upstream MetaStreet documentation, retained for reference.
- [`foundry.toml`](foundry.toml) — Foundry configuration.

## License

Pool contracts are primarily BUSL-1.1 [licensed](LICENSE) (© MetaStreet Labs).
Interfaces are MIT [licensed](contracts/interfaces/LICENSE).
