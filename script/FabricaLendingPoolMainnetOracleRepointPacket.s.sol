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
    function getERC20DepositTokenImplementation() external view returns (address);
    function liquidationGracePeriod() external view returns (uint64);
    function priceOracle() external view returns (address);
}

interface IMainnetOwnable {
    function owner() external view returns (address);
}

interface IHardenedSimpleSignedPriceOracle {
    function DOMAIN_VERSION() external view returns (string memory);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    function owner() external view returns (address);
}

error EnvAddressZero(string name);
error UnexpectedBeacon();
error UnexpectedPool();
error UnexpectedSafe();
error UnexpectedPoolAdmin();
error UnexpectedBeaconOwner();
error UnexpectedPoolAdminOwner();
error UnexpectedMultiSendCallOnly();
error MissingMultiSendCallOnlyCode();
error MissingNewImplementationCode();
error MissingGuardedOracleCode();
error UnexpectedCurrentImplementation();
error UnexpectedCurrentOracle();
error NoOpBeaconUpgrade();
error NoOpOracleRepoint();
error UnexpectedImplementationName();
error BadImplementationVersion();
error WrapperDrift();
error LiquidatorDrift();
error RegistryV1Drift();
error RegistryV2Drift();
error DepositTokenImplementationDrift();
error GracePeriodDrift();
error BadOracleVersion();
error BadOracleDomain();
error BadOracleDomainName();
error BadOracleDomainChain();
error BadOracleDomainVerifier();
error UnexpectedOracleOwner();

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
    address private constant CANONICAL_MAINNET_LENDING_BEACON = 0x30E9A2082E297a2E18615224A6146f6c73F7b7A6;
    address private constant CANONICAL_MAINNET_LENDING_POOL = 0x221014c0b6871f3F0d57F262ae6B5b6CD2901456;
    address private constant CANONICAL_MAINNET_LENDING_SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    address private constant CANONICAL_MAINNET_POOL_ADMIN = 0x759991Bf617BAc3728983bF03Fb4d744C51F2A4F;
    address private constant CANONICAL_MAINNET_CURRENT_IMPL = 0x623Ce6d9B158D007fD1E79e5a58B177aB9b51d78;
    address private constant CANONICAL_MAINNET_WEAK_ORACLE = 0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5;
    address private constant CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL = 0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634;
    address private constant CANONICAL_SAFE_MULTISEND_CALL_ONLY = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761;
    string private constant CANONICAL_ORACLE_DOMAIN_NAME = "All Fabrica Properties";

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
        if (beacon != CANONICAL_MAINNET_LENDING_BEACON) revert UnexpectedBeacon();
        if (pool != CANONICAL_MAINNET_LENDING_POOL) revert UnexpectedPool();
        if (expectedSafe != CANONICAL_MAINNET_LENDING_SAFE) revert UnexpectedSafe();
        if (poolAdmin != CANONICAL_MAINNET_POOL_ADMIN) revert UnexpectedPoolAdmin();
        if (beaconOwner != expectedSafe) revert UnexpectedBeaconOwner();
        if (poolAdminOwner != expectedSafe) revert UnexpectedPoolAdminOwner();
        if (multiSendCallOnly != CANONICAL_SAFE_MULTISEND_CALL_ONLY) revert UnexpectedMultiSendCallOnly();
        if (multiSendCallOnly.code.length == 0) revert MissingMultiSendCallOnlyCode();
        if (newImpl.code.length == 0) revert MissingNewImplementationCode();
        if (guardedOracle.code.length == 0) revert MissingGuardedOracleCode();
        if (currentImpl != CANONICAL_MAINNET_CURRENT_IMPL) revert UnexpectedCurrentImplementation();
        if (currentOracle != CANONICAL_MAINNET_WEAK_ORACLE) revert UnexpectedCurrentOracle();
        if (newImpl == currentImpl) revert NoOpBeaconUpgrade();
        if (guardedOracle == currentOracle) revert NoOpOracleRepoint();
        if (
            keccak256(bytes(IMainnetPool(newImpl).IMPLEMENTATION_NAME()))
                != keccak256(bytes("WeightedRateERC1155CollectionPool"))
        ) revert UnexpectedImplementationName();
        if (keccak256(bytes(IMainnetPool(newImpl).IMPLEMENTATION_VERSION())) != keccak256(bytes("2.16"))) {
            revert BadImplementationVersion();
        }
        if (!_sameAddressArray(IMainnetPool(newImpl).collateralWrappers(), IMainnetPool(pool).collateralWrappers())) {
            revert WrapperDrift();
        }
        if (IMainnetPool(newImpl).collateralLiquidator() != IMainnetPool(pool).collateralLiquidator()) {
            revert LiquidatorDrift();
        }
        if (IMainnetPool(newImpl).delegationRegistry() != IMainnetPool(pool).delegationRegistry()) {
            revert RegistryV1Drift();
        }
        if (IMainnetPool(newImpl).delegationRegistryV2() != IMainnetPool(pool).delegationRegistryV2()) {
            revert RegistryV2Drift();
        }
        if (
            IMainnetPool(newImpl).getERC20DepositTokenImplementation() != CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL
                || IMainnetPool(pool).getERC20DepositTokenImplementation() != CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL
        ) {
            revert DepositTokenImplementationDrift();
        }
        if (IMainnetPool(newImpl).liquidationGracePeriod() != IMainnetPool(pool).liquidationGracePeriod()) {
            revert GracePeriodDrift();
        }
        (
            ,
            string memory oracleDomainName,
            string memory oracleDomainVersion,
            uint256 oracleDomainChainId,
            address oracleDomainVerifier,,
        ) = IHardenedSimpleSignedPriceOracle(guardedOracle).eip712Domain();
        if (
            keccak256(bytes(IHardenedSimpleSignedPriceOracle(guardedOracle).IMPLEMENTATION_VERSION()))
                != keccak256(bytes("1.4"))
        ) revert BadOracleVersion();
        if (
            keccak256(bytes(IHardenedSimpleSignedPriceOracle(guardedOracle).DOMAIN_VERSION()))
                != keccak256(bytes("1.2"))
        ) {
            revert BadOracleDomain();
        }
        if (keccak256(bytes(oracleDomainName)) != keccak256(bytes(CANONICAL_ORACLE_DOMAIN_NAME))) {
            revert BadOracleDomainName();
        }
        if (keccak256(bytes(oracleDomainVersion)) != keccak256(bytes("1.2"))) revert BadOracleDomain();
        if (oracleDomainChainId != block.chainid) revert BadOracleDomainChain();
        if (oracleDomainVerifier != guardedOracle) revert BadOracleDomainVerifier();
        if (IHardenedSimpleSignedPriceOracle(guardedOracle).owner() != expectedSafe) revert UnexpectedOracleOwner();
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
        if (addr == address(0)) revert EnvAddressZero(name);
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
