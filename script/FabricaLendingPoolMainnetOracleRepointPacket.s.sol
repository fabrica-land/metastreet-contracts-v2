// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

interface IMainnetPool {
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function collateralLiquidator() external view returns (address);
    function collateralToken() external view returns (address);
    function currencyToken() external view returns (address);
    function priceOracle() external view returns (address);
}

interface IMainnetOwnable {
    function owner() external view returns (address);
}

interface IHardenedSimpleSignedPriceOracle {
    struct CollateralPolicy {
        address currencyToken;
        uint64 maxQuoteAge;
        uint64 maxDuration;
        uint64 maxReferenceAge;
        uint64 enabledGeneration;
        bool enabled;
        bool configured;
    }

    struct TokenPolicy {
        uint256 maxPrice;
        uint256 referencePrice;
        uint64 referenceUpdatedAt;
        uint16 maxDeviationBps;
        bool configured;
    }

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
    function pendingOwner() external view returns (address);
    function priceOracleSigner(address collateralToken) external view returns (address);
    function collateralPolicy(address collateralToken) external view returns (CollateralPolicy memory);
    function tokenPolicy(address collateralToken, uint256 tokenId) external view returns (TokenPolicy memory);
}

error EnvAddressZero(string name);
error EnvBytes32Zero(string name);
error EnvUintZero(string name);
error LiveTokenIdsRequired();
error UnexpectedPool();
error UnexpectedSafe();
error UnexpectedPoolAdmin();
error UnexpectedPoolAdminOwner();
error UnexpectedPoolVersion();
error UnexpectedCollateralToken();
error UnexpectedCurrencyToken();
error UnexpectedLiveLiquidator();
error MissingGuardedOracleCode();
error UnexpectedGuardedOracleCodehash();
error UnexpectedCurrentOracle();
error NoOpOracleRepoint();
error BadOracleVersion();
error BadOracleDomain();
error BadOracleDomainName();
error BadOracleDomainChain();
error BadOracleDomainVerifier();
error UnexpectedOracleOwner();
error UnexpectedOraclePendingOwner();
error MissingSignerContract();
error BadCollateralPolicy();
error BadTokenPolicy(uint256 tokenId);
error ReferenceStale(uint256 tokenId);
error ReferenceRefreshSlaTooLoose();

/**
 * @title Fabrica mainnet lending pool oracle repoint Safe packet
 * @notice Dry-run only. Prints calldata for a single operator-reviewed Safe
 *         CALL: pool.setPriceOracle(guardedOracle). No beacon upgrade, new pool
 *         implementation, or liquidator replacement is prepared here.
 */
contract FabricaLendingPoolMainnetOracleRepointPacketScript is Script {
    bytes4 private constant SET_PRICE_ORACLE_SELECTOR = 0x530e784f;
    uint64 private constant MAX_REFERENCE_AGE = 30 days;

    address private constant CANONICAL_MAINNET_LENDING_POOL = 0x221014c0b6871f3F0d57F262ae6B5b6CD2901456;
    address private constant CANONICAL_MAINNET_LENDING_SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    address private constant CANONICAL_MAINNET_POOL_ADMIN = 0x759991Bf617BAc3728983bF03Fb4d744C51F2A4F;
    address private constant CANONICAL_MAINNET_WEAK_ORACLE = 0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5;
    address private constant CANONICAL_MAINNET_COLLATERAL_TOKEN = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address private constant CANONICAL_MAINNET_CURRENCY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant CANONICAL_MAINNET_LIQUIDATOR = 0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B;
    string private constant CANONICAL_ORACLE_DOMAIN_NAME = "All Fabrica Properties";

    function setUp() public {}

    function run() public view {
        address pool = _requireEnvAddress("FABRICA_MAINNET_LENDING_POOL");
        address expectedSafe = _requireEnvAddress("FABRICA_MAINNET_LENDING_SAFE");
        address guardedOracle = _requireEnvAddress("FABRICA_MAINNET_GUARDED_PRICE_ORACLE");
        bytes32 expectedGuardedOracleCodehash = _requireEnvBytes32("FABRICA_MAINNET_GUARDED_PRICE_ORACLE_CODEHASH");
        uint256[] memory liveTokenIds = vm.envUint("FABRICA_MAINNET_LIVE_TOKEN_IDS", ",");
        uint256 referenceRefreshSla = _requireEnvUint("FABRICA_MAINNET_REFERENCE_REFRESH_SLA_SECONDS");

        _validatePoolPrestate(pool, expectedSafe, guardedOracle);
        _validateGuardedOracle(
            guardedOracle,
            expectedGuardedOracleCodehash,
            expectedSafe,
            IMainnetPool(pool).collateralToken(),
            IMainnetPool(pool).currencyToken(),
            liveTokenIds,
            referenceRefreshSla
        );

        bytes memory repointCall = abi.encodeWithSelector(SET_PRICE_ORACLE_SELECTOR, guardedOracle);

        console.log("=== ENG-3695 mainnet oracle-only Safe packet dry-run ===");
        console.log("Safe:                  ", expectedSafe);
        console.log("Call target:           ", pool);
        console.log("Operation:             CALL");
        console.log("Value:                 0");
        console.log("Current price oracle:  ", IMainnetPool(pool).priceOracle());
        console.log("Guarded price oracle:  ", guardedOracle);
        console.log("Live liquidator kept:  ", IMainnetPool(pool).collateralLiquidator());
        console.log("Calldata:");
        console.logBytes(repointCall);
        console.log("Required postconditions after Safe execution:");
        console.log("- pool.priceOracle() == guarded price oracle");
        console.log("- guarded oracle signer has code");
        console.log("- guarded oracle market remains enabled for the complete live token-ID list");
        console.log("- monitored reference-price refresh SLA remains inside maxReferenceAge");
    }

    function _validatePoolPrestate(address pool, address expectedSafe, address guardedOracle) private view {
        if (pool != CANONICAL_MAINNET_LENDING_POOL) revert UnexpectedPool();
        if (expectedSafe != CANONICAL_MAINNET_LENDING_SAFE) revert UnexpectedSafe();

        IMainnetPool livePool = IMainnetPool(pool);
        address poolAdmin = livePool.admin();
        address poolAdminOwner = IMainnetOwnable(poolAdmin).owner();
        address currentOracle = livePool.priceOracle();

        if (poolAdmin != CANONICAL_MAINNET_POOL_ADMIN) revert UnexpectedPoolAdmin();
        if (poolAdminOwner != expectedSafe) revert UnexpectedPoolAdminOwner();
        if (keccak256(bytes(livePool.IMPLEMENTATION_VERSION())) != keccak256(bytes("2.15"))) {
            revert UnexpectedPoolVersion();
        }
        if (livePool.collateralToken() != CANONICAL_MAINNET_COLLATERAL_TOKEN) revert UnexpectedCollateralToken();
        if (livePool.currencyToken() != CANONICAL_MAINNET_CURRENCY_TOKEN) revert UnexpectedCurrencyToken();
        if (livePool.collateralLiquidator() != CANONICAL_MAINNET_LIQUIDATOR) revert UnexpectedLiveLiquidator();
        if (currentOracle != CANONICAL_MAINNET_WEAK_ORACLE) revert UnexpectedCurrentOracle();
        if (guardedOracle == currentOracle) revert NoOpOracleRepoint();
    }

    function _validateGuardedOracle(
        address guardedOracle,
        bytes32 expectedCodehash,
        address expectedSafe,
        address collateralToken,
        address currencyToken,
        uint256[] memory liveTokenIds,
        uint256 referenceRefreshSla
    ) private view {
        if (guardedOracle.code.length == 0) revert MissingGuardedOracleCode();
        if (guardedOracle.codehash != expectedCodehash) revert UnexpectedGuardedOracleCodehash();
        if (liveTokenIds.length == 0) revert LiveTokenIdsRequired();

        IHardenedSimpleSignedPriceOracle oracle = IHardenedSimpleSignedPriceOracle(guardedOracle);
        (
            ,
            string memory oracleDomainName,
            string memory oracleDomainVersion,
            uint256 oracleDomainChainId,
            address oracleDomainVerifier,,
        ) = oracle.eip712Domain();

        if (keccak256(bytes(oracle.IMPLEMENTATION_VERSION())) != keccak256(bytes("1.4"))) revert BadOracleVersion();
        if (keccak256(bytes(oracle.DOMAIN_VERSION())) != keccak256(bytes("1.2"))) revert BadOracleDomain();
        if (keccak256(bytes(oracleDomainName)) != keccak256(bytes(CANONICAL_ORACLE_DOMAIN_NAME))) {
            revert BadOracleDomainName();
        }
        if (keccak256(bytes(oracleDomainVersion)) != keccak256(bytes("1.2"))) revert BadOracleDomain();
        if (oracleDomainChainId != block.chainid) revert BadOracleDomainChain();
        if (oracleDomainVerifier != guardedOracle) revert BadOracleDomainVerifier();
        if (oracle.owner() != expectedSafe) revert UnexpectedOracleOwner();
        if (oracle.pendingOwner() != address(0)) revert UnexpectedOraclePendingOwner();

        address signer = oracle.priceOracleSigner(collateralToken);
        if (signer.code.length == 0) revert MissingSignerContract();

        IHardenedSimpleSignedPriceOracle.CollateralPolicy memory policy = oracle.collateralPolicy(collateralToken);
        if (
            !policy.configured || !policy.enabled || policy.currencyToken != currencyToken
                || policy.maxReferenceAge == 0 || policy.maxReferenceAge > MAX_REFERENCE_AGE
        ) revert BadCollateralPolicy();
        if (referenceRefreshSla == 0 || referenceRefreshSla > policy.maxReferenceAge / 2) {
            revert ReferenceRefreshSlaTooLoose();
        }

        for (uint256 i; i < liveTokenIds.length; i++) {
            IHardenedSimpleSignedPriceOracle.TokenPolicy memory tokenPolicy =
                oracle.tokenPolicy(collateralToken, liveTokenIds[i]);
            if (
                !tokenPolicy.configured || tokenPolicy.maxPrice == 0 || tokenPolicy.referencePrice == 0
                    || tokenPolicy.referencePrice > tokenPolicy.maxPrice || tokenPolicy.referenceUpdatedAt == 0
                    || tokenPolicy.referenceUpdatedAt > block.timestamp
            ) revert BadTokenPolicy(liveTokenIds[i]);
            if (block.timestamp - tokenPolicy.referenceUpdatedAt > policy.maxReferenceAge) {
                revert ReferenceStale(liveTokenIds[i]);
            }
        }
    }

    function _requireEnvAddress(string memory name) private view returns (address addr) {
        addr = vm.envAddress(name);
        if (addr == address(0)) revert EnvAddressZero(name);
    }

    function _requireEnvBytes32(string memory name) private view returns (bytes32 value) {
        value = vm.envBytes32(name);
        if (value == bytes32(0)) revert EnvBytes32Zero(name);
    }

    function _requireEnvUint(string memory name) private view returns (uint256 value) {
        value = vm.envUint(name);
        if (value == 0) revert EnvUintZero(name);
    }
}
