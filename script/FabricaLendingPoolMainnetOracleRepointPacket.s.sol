// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

interface IMainnetBeacon {
    function implementation() external view returns (address);
    function owner() external view returns (address);
}

interface IMainnetPool {
    function IMPLEMENTATION_NAME() external view returns (string memory);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function collateralLiquidator() external view returns (address);
    function collateralWrappers() external view returns (address[] memory);
    function delegationRegistry() external view returns (address);
    function delegationRegistryV2() external view returns (address);
    function liquidationGracePeriod() external view returns (uint64);
    function priceOracle() external view returns (address);
}

interface IMainnetOwnable {
    function owner() external view returns (address);
}

interface IHardenedSimpleSignedPriceOracle {
    function DOMAIN_VERSION() external view returns (string memory);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function owner() external view returns (address);
}

/**
 * @title Fabrica mainnet lending pool oracle repoint Safe packet
 * @notice Dry-run only. Prints calldata for operator-reviewed Safe execution:
 *         1. beacon.upgradeTo(newImpl)
 *         2. pool.setPriceOracle(guardedOracle)
 *         plus the exact Safe MultiSendCallOnly payload wrapping both calls.
 */
contract FabricaLendingPoolMainnetOracleRepointPacketScript is Script {
    bytes1 private constant CALL_OPERATION = 0x00;
    bytes4 private constant MULTISEND_SELECTOR = 0x8d80ff0a;
    bytes4 private constant UPGRADE_TO_SELECTOR = 0x3659cfe6;
    bytes4 private constant SET_PRICE_ORACLE_SELECTOR = 0x530e784f;
    address private constant CANONICAL_SAFE_MULTISEND_CALL_ONLY = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761;

    function setUp() public {}

    function run() public view {
        address beacon = _requireEnvAddress("FABRICA_MAINNET_LENDING_BEACON");
        address pool = _requireEnvAddress("FABRICA_MAINNET_LENDING_POOL");
        address expectedSafe = _requireEnvAddress("FABRICA_MAINNET_LENDING_SAFE");
        address multiSendCallOnly = _requireEnvAddress("FABRICA_MAINNET_SAFE_MULTISEND_CALL_ONLY");
        address newImpl = _requireEnvAddress("FABRICA_MAINNET_LENDING_NEW_IMPL");
        address guardedOracle = _requireEnvAddress("FABRICA_MAINNET_GUARDED_PRICE_ORACLE");
        address beaconOwner = IMainnetBeacon(beacon).owner();
        address poolAdmin = IMainnetPool(pool).admin();
        address poolAdminOwner = IMainnetOwnable(poolAdmin).owner();
        address currentImpl = IMainnetBeacon(beacon).implementation();
        address currentOracle = IMainnetPool(pool).priceOracle();
        require(beaconOwner == expectedSafe, "unexpected beacon owner");
        require(poolAdminOwner == expectedSafe, "unexpected pool admin owner");
        require(multiSendCallOnly == CANONICAL_SAFE_MULTISEND_CALL_ONLY, "unexpected MultiSendCallOnly");
        require(multiSendCallOnly.code.length != 0, "MultiSendCallOnly has no code");
        require(newImpl.code.length != 0, "new impl has no code");
        require(guardedOracle.code.length != 0, "guarded oracle has no code");
        require(newImpl != currentImpl, "no-op beacon upgrade");
        require(guardedOracle != currentOracle, "no-op oracle repoint");
        require(
            keccak256(bytes(IMainnetPool(newImpl).IMPLEMENTATION_NAME()))
                == keccak256(bytes("WeightedRateERC1155CollectionPool")),
            "unexpected impl name"
        );
        require(
            keccak256(bytes(IMainnetPool(newImpl).IMPLEMENTATION_VERSION())) == keccak256(bytes("2.16")),
            "bad impl version"
        );
        require(
            _sameAddressArray(IMainnetPool(newImpl).collateralWrappers(), IMainnetPool(pool).collateralWrappers()),
            "wrapper drift"
        );
        require(
            IMainnetPool(newImpl).collateralLiquidator() == IMainnetPool(pool).collateralLiquidator(),
            "liquidator drift"
        );
        require(
            IMainnetPool(newImpl).delegationRegistry() == IMainnetPool(pool).delegationRegistry(), "registry v1 drift"
        );
        require(
            IMainnetPool(newImpl).delegationRegistryV2() == IMainnetPool(pool).delegationRegistryV2(),
            "registry v2 drift"
        );
        require(
            IMainnetPool(newImpl).liquidationGracePeriod() == IMainnetPool(pool).liquidationGracePeriod(), "grace drift"
        );
        require(
            keccak256(bytes(IHardenedSimpleSignedPriceOracle(guardedOracle).IMPLEMENTATION_VERSION()))
                == keccak256(bytes("1.4")),
            "bad oracle version"
        );
        require(
            keccak256(bytes(IHardenedSimpleSignedPriceOracle(guardedOracle).DOMAIN_VERSION()))
                == keccak256(bytes("1.2")),
            "bad oracle domain"
        );
        require(IHardenedSimpleSignedPriceOracle(guardedOracle).owner() == expectedSafe, "unexpected oracle owner");
        bytes memory upgradeCall = abi.encodeWithSelector(UPGRADE_TO_SELECTOR, newImpl);
        bytes memory repointCall = abi.encodeWithSelector(SET_PRICE_ORACLE_SELECTOR, guardedOracle);
        bytes memory multiSendTransactions =
            bytes.concat(_multiSendTx(beacon, upgradeCall), _multiSendTx(pool, repointCall));
        bytes memory multiSendCall = abi.encodeWithSelector(MULTISEND_SELECTOR, multiSendTransactions);
        console.log("=== ENG-3686 Safe packet dry-run ===");
        console.log("Beacon owner Safe:         ", expectedSafe);
        console.log("MultiSendCallOnly:         ", multiSendCallOnly);
        console.log("Beacon:                    ", beacon);
        console.log("Pool:                      ", pool);
        console.log("Current implementation:    ", currentImpl);
        console.log("New implementation:        ", newImpl);
        console.log("Current price oracle:      ", currentOracle);
        console.log("Guarded price oracle:      ", guardedOracle);
        console.log("Post-upgrade pool version: ", IMainnetPool(newImpl).IMPLEMENTATION_VERSION());
        console.log("Call 1 target:             ", beacon);
        console.logBytes(upgradeCall);
        console.log("Call 2 target:             ", pool);
        console.logBytes(repointCall);
        console.log("MultiSendCallOnly target:  ", multiSendCallOnly);
        console.log("Safe operation:            DELEGATECALL to MultiSendCallOnly");
        console.log("MultiSendCallOnly calldata:");
        console.logBytes(multiSendCall);
        console.log("Encoded CallOnly transaction bytes:");
        console.logBytes(multiSendTransactions);
        console.log("Required postconditions:");
        console.log("- beacon.implementation() == new implementation");
        console.log("- pool.IMPLEMENTATION_VERSION() == 2.16");
        console.log("- pool.priceOracle() == guarded price oracle");
        console.log("- pool admin and balances/loan state unchanged");
        console.log(
            "- partial upgrade-only resting state is safe but incomplete: pool remains on the old oracle until call 2"
        );
    }

    function _requireEnvAddress(string memory name) private view returns (address addr) {
        addr = vm.envAddress(name);
        require(addr != address(0), string.concat(name, " is zero"));
    }

    function _multiSendTx(address to, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(CALL_OPERATION, to, uint256(0), data.length, data);
    }

    function _sameAddressArray(address[] memory a, address[] memory b) private pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
