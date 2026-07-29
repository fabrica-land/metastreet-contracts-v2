// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {PoolFactory} from "fabrica-lending-pools/PoolFactory.sol";

/**
 * @title Launch path: BeaconProxy pool wired to renounced FabricaOracleAggregator
 *
 * ENG-3519 WP-B. Creates a WeightedRateERC1155CollectionPool via
 * `PoolFactory.createProxied` with `priceOracle` set to the renounced
 * aggregator (IPriceOracle), not SimpleSignedPriceOracle and not the fact store.
 *
 * Empty `oracleContext` is the launch borrow path — the aggregator reads only
 * on-chain FAO facts.
 *
 * **No on-chain deploys from agents.** Tim/Fede-gated operators may broadcast.
 * Agents: forge script without --broadcast for dry-run; anvil for FV.
 *
 * Required env:
 *   FABRICA_LENDING_FACTORY
 *   FABRICA_LENDING_BEACON
 *   FABRICA_LENDING_AGGREGATOR   renounced FabricaOracleAggregator address
 *   FABRICA_LENDING_CURRENCY_TOKEN
 *   FABRICA_LENDING_COLLATERAL_TOKEN
 *
 * Optional:
 *   FABRICA_LENDING_DRY_RUN=true  — log params only, no broadcast (default true for agents)
 */
contract FabricaLendingPoolCreateWithAggregatorScript is Script {
    function run() public {
        address factory = vm.envAddress("FABRICA_LENDING_FACTORY");
        address beacon = vm.envAddress("FABRICA_LENDING_BEACON");
        address aggregator = vm.envAddress("FABRICA_LENDING_AGGREGATOR");
        address currencyToken = vm.envAddress("FABRICA_LENDING_CURRENCY_TOKEN");
        address collateralToken = vm.envAddress("FABRICA_LENDING_COLLATERAL_TOKEN");
        bool dryRun = vm.envOr("FABRICA_LENDING_DRY_RUN", true);
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = collateralToken;
        uint64[] memory durations = _defaultDurations();
        uint64[] memory rates = _defaultRates();
        bytes memory params = abi.encode(collateralTokens, currencyToken, aggregator, durations, rates);
        console.log("=== ENG-3519 WP-B launch path (createProxied -> aggregator) ===");
        console.log("Factory:     ", factory);
        console.log("Beacon:      ", beacon);
        console.log("Aggregator:  ", aggregator);
        console.log("Currency:    ", currencyToken);
        console.log("Collateral:  ", collateralToken);
        console.log("Mode:        ", dryRun ? "DRY_RUN (no broadcast)" : "BROADCAST");
        console.log("Params len:  ", params.length);
        if (dryRun) {
            console.log("Dry-run complete - operator broadcasts with FABRICA_LENDING_DRY_RUN=false");
            return;
        }
        vm.startBroadcast();
        address pool = PoolFactory(factory).createProxied(beacon, params);
        vm.stopBroadcast();
        console.log("=== Pool created ===");
        console.log("Pool (BeaconProxy):", pool);
    }

    /// @notice Mainnet duration tiers (strictly descending) — Pool.initialize requires durations[i] < durations[i-1].
    function _defaultDurations() internal pure returns (uint64[] memory durations) {
        durations = new uint64[](8);
        durations[0] = 62208000;
        durations[1] = 31104000;
        durations[2] = 23328000;
        durations[3] = 15552000;
        durations[4] = 10368000;
        durations[5] = 7776000;
        durations[6] = 5184000;
        durations[7] = 2592000;
    }

    /// @notice Mainnet rate tiers (ascending APR ~5/7/10/13/15/17/20/25 %), per-second 1e18-scaled.
    function _defaultRates() internal pure returns (uint64[] memory rates) {
        rates = new uint64[](8);
        rates[0] = 1585489599;
        rates[1] = 2219685438;
        rates[2] = 3170979198;
        rates[3] = 4122272957;
        rates[4] = 4756468797;
        rates[5] = 5390664637;
        rates[6] = 6341958396;
        rates[7] = 7927447995;
    }
}
