# Threat model: Fabrica MetaStreet lending fork

## Assets and entry points

Pools hold ERC-20 liquidity, issue deposit-token claims, and escrow ERC-1155 collateral for loans. Repayment, liquidation, and withdrawal move value among borrowers, lenders, and administrators. Review untrusted calls to `borrow`, `repay`, `depositFor`, and pool creation for balance, receipt, collateral, and recipient errors.
<!-- Source: README.md:3-30; contracts/Pool.sol:778-851,1054-1172; LENDING-POOL-RUNBOOK.md:9-25 -->

## Privileged roles and signing authority

The PoolFactory owner can set pool fees and rates, withdraw admin fees, allowlist pool implementations, and upgrade the factory proxy. The beacon owner can replace the implementation used by all attached pools. The price-oracle owner sets signer and pricing policy; a quote signer is trusted for collateral valuation. On mainnet the runbook names a Safe as beacon and factory owner. Review both authorization and the consequences of an authorized but unsafe setting.
<!-- Source: contracts/PoolFactory.sol:164-243; LENDING-POOL-RUNBOOK.md:40-83,87-115; contracts/oracle/SimpleSignedPriceOracle.sol:269-274 -->

## Upgrades

The factory uses an ERC-1967 proxy and creates pool BeaconProxies. Upgrading a beacon changes the implementation seen by every pool attached to it, without a per-pool upgrade. The merged 2.16 oracle-repoint path takes effect immediately when an authorized caller uses it; any delay exists in Safe operations rather than pool bytecode. Review upgrade compatibility, initializer behavior, and oracle changes as shared-pool risks.
<!-- Source: contracts/PoolFactory.sol:86-115,233-243; LENDING-POOL-RUNBOOK.md:110-116,340-365 -->

## Oracle and external trust

A pool relies on its configured price oracle, currency and collateral token behavior, its collateral wrapper, and auction liquidator. The runbook documents signer rotation and collateral controls for the signed oracle. It also identifies the mainnet oracle as weak and calls for replacement before launch liquidity. A manipulated quote or faulty external contract can change borrowing and liquidation outcomes.
<!-- Source: LENDING-POOL-RUNBOOK.md:9-25,40-105; contracts/oracle/SimpleSignedPriceOracle.sol:269-274 -->

## Scope

In scope: pool accounting, loan receipts, lending and liquidation logic, oracle verification and governance, pool factory authorization, and the behavior of configured wrappers and liquidators in `contracts/`. Out of scope: unrelated Fabrica token and settlement implementations in a different repository, failures solely within external token contracts, and deployments not identified in this repository's runbook. Fork tests self-skip without an RPC setting; this does not prove live-chain behavior.
<!-- Source: README.md:3-49,64-76; LENDING-POOL-RUNBOOK.md:9-25; contracts/Pool.sol:778-851 -->

## Known accepted risks

Beacon upgrades change all attached pools at once. The runbook says 2.16 oracle repointing has no on-chain delay, so operations must supply the proposed Safe delay. Mainnet's listed oracle is marked weak pending replacement; do not infer that a planned cutover is deployed. Reviewers should report an exploitable crossing of these boundaries, including unexpected authority or asset loss.
<!-- Source: LENDING-POOL-RUNBOOK.md:87-116,340-365 -->

## Why this fork is distinct

Measured 2026-10-19T17:02:50Z against `metastreet-labs/metastreet-contracts-v2`: its latest commit was 2025-02-12T23:16:29Z (`8ed467d272a2cee35751e60851fa1b830e2fe018`), and its last push was 2025-07-10T17:05:10Z. It is unmaintained by its authors for our current lending requirements, although GitHub reports `archived=false`. Fabrica main is 28 commits ahead, 0 behind, with 132 files changed. The fork adds third-party deposit crediting, permissionless repayment, configurable liquidation grace, and a designated borrower. Other commits replace Hardhat with Foundry, move logic into libraries for EIP-170 size, record ownership and deployments, harden and then revert oracle and auction changes, and add an oracle-repoint and launch path. These changes make the fork's behavior and review surface distinct from upstream.
<!-- Source: README.md:3-47; LENDING-POOL-RUNBOOK.md:299-306,340-365; GitHub compare and commit APIs measured 2026-10-19T17:02:50Z -->

Live chain readback on 2026-10-19 through Fabrica's configured RPCs confirms that the Sepolia pool `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` uses beacon `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e`, whose implementation is `0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5` (block 11950090). The mainnet pool `0x221014c0b6871f3F0d57F262ae6B5b6CD2901456` uses beacon `0x30E9A2082E297a2E18615224A6146f6c73F7b7A6`, whose implementation is `0x623Ce6d9B158D007fD1E79e5a58B177aB9b51d78` (block 26228563). These two pool implementations run the Fabrica fork: the Sepolia implementation is the designated-borrower release recorded in the runbook, and the mainnet implementation is the deployment recorded in the repository's mainnet broadcast artifact. Each beacon upgrade changes the code executed by its attached pool.
<!-- Source: LENDING-POOL-RUNBOOK.md:9-35,87-116,299-306; broadcast/FabricaLendingPoolStackDeploy.s.sol/1/run-latest.json; live eth_getStorageAt(EIP-1967 beacon slot) and UpgradeableBeacon.implementation() reads at the stated blocks -->
