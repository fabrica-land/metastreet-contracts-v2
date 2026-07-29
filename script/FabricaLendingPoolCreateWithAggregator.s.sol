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

    function _defaultDurations() internal pure returns (uint64[] memory durations) {
        durations = new uint64[](3);
        durations[0] = 7 days;
        durations[1] = 14 days;
        durations[2] = 30 days;
    }

    function _defaultRates() internal pure returns (uint64[] memory rates) {
        // Interest per second placeholders — operator overrides via env later if needed.
        rates = new uint64[](3);
        rates[0] = 1;
        rates[1] = 2;
        rates[2] = 3;
    }
}
