// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title setPriceOracle calldata helper (ENG-3519 WP-B)
 *
 * After beacon upgrade to IMPLEMENTATION_VERSION 2.16, pool admin (or
 * Ownable(admin).owner) can call setPriceOracle(newAggregator).
 *
 * Operational 48h delay: queue the call through the Safe delay module —
 * on-chain timelock does not fit under EIP-170 with Fabrica pool deltas.
 *
 * Agents: dry-run only. No on-chain deploys or broadcasts.
 *
 * Required env:
 *   FABRICA_LENDING_POOL
 *   FABRICA_LENDING_AGGREGATOR
 * Optional:
 *   FABRICA_LENDING_DRY_RUN=true (default)
 */
contract FabricaLendingPoolScheduleOracleScript is Script {
    function run() public {
        address pool = vm.envAddress("FABRICA_LENDING_POOL");
        address aggregator = vm.envAddress("FABRICA_LENDING_AGGREGATOR");
        bool dryRun = vm.envOr("FABRICA_LENDING_DRY_RUN", true);
        bytes memory data = abi.encodeWithSignature("setPriceOracle(address)", aggregator);
        console.log("setPriceOracle ->", aggregator);
        console.log("Pool:   ", pool);
        console.logBytes(data);
        console.log("Mode:   ", dryRun ? "DRY_RUN" : "BROADCAST");
        console.log("Note: use Safe delay module for operational 48h timelock");
        if (dryRun) return;
        vm.startBroadcast();
        (bool ok, bytes memory ret) = pool.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        vm.stopBroadcast();
        console.log("ok");
    }
}
