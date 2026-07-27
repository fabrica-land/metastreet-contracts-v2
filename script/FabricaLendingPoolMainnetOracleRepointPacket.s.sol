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
    function collateralToken() external view returns (address);
    function collateralWrappers() external view returns (address[] memory);
    function currencyToken() external view returns (address);
    function delegationRegistry() external view returns (address);
    function delegationRegistryV2() external view returns (address);
    function getERC20DepositTokenImplementation() external view returns (address);
    function liquidationGracePeriod() external view returns (uint64);
    function priceOracle() external view returns (address);
    function rates() external view returns (uint64[] memory);
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
    function tokenPolicyGeneration(address collateralToken, uint256 tokenId) external view returns (uint64);
}

error EnvAddressZero(string name);
error EnvBytes32Zero(string name);
error EnvUintZero(string name);
error TokenIdsEmpty();
error TokenIdsNotStrictlyAscending();
error CollateralGenerationZero();
error TokenGenerationMismatch(uint256 tokenId);
error TokenIdCollidesWithRate(uint256 tokenId);
error PolicyValueLengthMismatch();
error UnexpectedTokenMaxPrice(uint256 tokenId);
error UnexpectedTokenReferencePrice(uint256 tokenId);
error MissingLinkedLibraryCode(address library_);
error UnexpectedLinkedLibraryCodehash(address library_);
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
error GuardedOracleMustBeDirect();
error UnexpectedNewImplementationCodehash();
error UnexpectedGuardedOracleCodehash();
error UnexpectedCurrentImplementation();
error UnexpectedCurrentOracle();
error NoOpBeaconUpgrade();
error NoOpOracleRepoint();
error UnexpectedImplementationName();
error UnexpectedCurrentPoolVersion();
error BadImplementationVersion();
error UnexpectedCollateralToken();
error UnexpectedCurrencyToken();
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
error UnexpectedOraclePendingOwner();
error UnexpectedOracleSigner();
error BadCollateralPolicy();
error BadTokenPolicy(uint256 tokenId);
error ReferenceStale(uint256 tokenId);
error ReferenceRefreshSlaTooLoose();

/**
 * @title Fabrica mainnet lending pool oracle repoint Safe packet
 * @notice Dry-run only. Prints calldata for an operator-reviewed Safe
 *         DELEGATECALL to MultiSendCallOnly:
 *         1. UpgradeableBeacon.upgradeTo(new no-floor 2.16 implementation)
 *         2. pool.setPriceOracle(guardedOracle)
 */
contract FabricaLendingPoolMainnetOracleRepointPacketScript is Script {
    bytes1 private constant CALL_OPERATION = 0x00;
    bytes4 private constant MULTISEND_SELECTOR = 0x8d80ff0a;
    bytes4 private constant UPGRADE_TO_SELECTOR = 0x3659cfe6;
    bytes4 private constant SET_PRICE_ORACLE_SELECTOR = 0x530e784f;
    uint64 private constant MAX_REFERENCE_AGE = 30 days;

    address private constant CANONICAL_MAINNET_LENDING_BEACON = 0x30E9A2082E297a2E18615224A6146f6c73F7b7A6;
    address private constant CANONICAL_MAINNET_LENDING_POOL = 0x221014c0b6871f3F0d57F262ae6B5b6CD2901456;
    address private constant CANONICAL_MAINNET_LENDING_SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    address private constant CANONICAL_MAINNET_POOL_ADMIN = 0x759991Bf617BAc3728983bF03Fb4d744C51F2A4F;
    address private constant CANONICAL_MAINNET_CURRENT_IMPL = 0x623Ce6d9B158D007fD1E79e5a58B177aB9b51d78;
    address private constant CANONICAL_MAINNET_WEAK_ORACLE = 0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5;
    address private constant CANONICAL_MAINNET_COLLATERAL_TOKEN = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address private constant CANONICAL_MAINNET_CURRENCY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant CANONICAL_MAINNET_LIQUIDATOR = 0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B;
    address private constant CANONICAL_MAINNET_DELEGATE_REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    address private constant CANONICAL_MAINNET_DELEGATE_REGISTRY_V2 = 0x00000000000000447e69651d841bD8D104Bed493;
    address private constant CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL = 0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634;
    address private constant CANONICAL_MAINNET_COLLATERAL_WRAPPER = 0x05489aC114fBaaedeE4a49B67fCc5666C951E552;
    address private constant CANONICAL_SAFE_MULTISEND_CALL_ONLY = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761;
    uint64 private constant CANONICAL_MAINNET_LIQUIDATION_GRACE_PERIOD = 15 days;
    address private constant CANONICAL_MAINNET_ORACLE_SIGNER = 0xC888f5e3Dd4FBeB37f6e1bA6FA68c83aB0cf7B2c;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    string private constant CANONICAL_ORACLE_DOMAIN_NAME = "All US Land";

    function setUp() public {}

    function run() public view {
        address beacon = _requireEnvAddress("FABRICA_MAINNET_LENDING_BEACON");
        address pool = _requireEnvAddress("FABRICA_MAINNET_LENDING_POOL");
        address expectedSafe = _requireEnvAddress("FABRICA_MAINNET_LENDING_SAFE");
        address multiSendCallOnly = _requireEnvAddress("FABRICA_MAINNET_SAFE_MULTISEND_CALL_ONLY");
        address newImpl = _requireEnvAddress("FABRICA_MAINNET_LENDING_NEW_IMPL");
        address guardedOracle = _requireEnvAddress("FABRICA_MAINNET_GUARDED_PRICE_ORACLE");
        bytes32 expectedNewImplCodehash = _requireEnvBytes32("FABRICA_MAINNET_LENDING_NEW_IMPL_CODEHASH");
        bytes32 expectedGuardedOracleCodehash = _requireEnvBytes32("FABRICA_MAINNET_GUARDED_PRICE_ORACLE_CODEHASH");
        uint256[] memory liveTokenIds = vm.envUint("FABRICA_MAINNET_LIVE_TOKEN_IDS", ",");
        uint256 referenceRefreshSla = _requireEnvUint("FABRICA_MAINNET_REFERENCE_REFRESH_SLA_SECONDS");
        uint256[] memory expectedMaxPrices = vm.envUint("FABRICA_MAINNET_TOKEN_MAX_PRICES", ",");
        uint256[] memory expectedReferencePrices = vm.envUint("FABRICA_MAINNET_TOKEN_REFERENCE_PRICES", ",");

        _validatePoolAndImplementationPrestate(beacon, pool, expectedSafe, multiSendCallOnly, newImpl, guardedOracle);
        _validateLinkedLibraries();
        _validateGuardedOracle(
            guardedOracle,
            expectedGuardedOracleCodehash,
            expectedSafe,
            IMainnetPool(pool).collateralToken(),
            IMainnetPool(pool).currencyToken(),
            liveTokenIds,
            referenceRefreshSla,
            IMainnetPool(pool).rates(),
            expectedMaxPrices,
            expectedReferencePrices
        );

        if (newImpl.codehash != expectedNewImplCodehash) revert UnexpectedNewImplementationCodehash();
        (bytes memory multiSendTransactions, bytes memory multiSendCall) =
            _buildMultiSendCall(beacon, pool, newImpl, guardedOracle);
        bytes memory upgradeCall = abi.encodeWithSelector(UPGRADE_TO_SELECTOR, newImpl);
        bytes memory repointCall = abi.encodeWithSelector(SET_PRICE_ORACLE_SELECTOR, guardedOracle);

        console.log("=== ENG-3695 mainnet no-floor implementation + oracle Safe packet dry-run ===");
        console.log("Beacon owner Safe:         ", expectedSafe);
        console.log("MultiSendCallOnly:         ", multiSendCallOnly);
        console.log("Beacon:                    ", beacon);
        console.log("Pool:                      ", pool);
        console.log("Current implementation:    ", IMainnetBeacon(beacon).implementation());
        console.log("New no-floor implementation:", newImpl);
        console.log("Current price oracle:      ", IMainnetPool(pool).priceOracle());
        console.log("Guarded price oracle:      ", guardedOracle);
        console.log("Live liquidator kept:      ", IMainnetPool(pool).collateralLiquidator());
        console.log("Post-upgrade pool version: ", IMainnetPool(newImpl).IMPLEMENTATION_VERSION());
        console.log("Call 1 target:             ", beacon);
        console.logBytes(upgradeCall);
        console.log("Call 2 target:             ", pool);
        console.logBytes(repointCall);
        console.log("Safe target:               ", multiSendCallOnly);
        console.log("Safe operation:            DELEGATECALL");
        console.log("Safe value:                0");
        console.log("MultiSendCallOnly calldata:");
        console.logBytes(multiSendCall);
        console.log("Encoded CallOnly transaction bytes:");
        console.logBytes(multiSendTransactions);
        console.log("Enabled collateral token-ID count:", liveTokenIds.length);
        for (uint256 i; i < liveTokenIds.length; i++) {
            console.log("  enabled collateral token ID:", liveTokenIds[i]);
        }
        console.log("Required postconditions after Safe execution:");
        console.log("- beacon.implementation() == new no-floor implementation");
        console.log("- pool.IMPLEMENTATION_VERSION() == 2.16");
        console.log("- pool.collateralLiquidator() == live legacy liquidator");
        console.log("- pool.priceOracle() == guarded price oracle");
        console.log("- guarded oracle signer == expected EOA");
        console.log("- guarded oracle market remains enabled for the complete live token-ID list");
        console.log("- monitored reference-price refresh SLA remains inside maxReferenceAge");
    }

    function _validatePoolAndImplementationPrestate(
        address beacon,
        address pool,
        address expectedSafe,
        address multiSendCallOnly,
        address newImpl,
        address guardedOracle
    ) private view {
        if (beacon != CANONICAL_MAINNET_LENDING_BEACON) revert UnexpectedBeacon();
        if (pool != CANONICAL_MAINNET_LENDING_POOL) revert UnexpectedPool();
        if (expectedSafe != CANONICAL_MAINNET_LENDING_SAFE) revert UnexpectedSafe();
        if (multiSendCallOnly != CANONICAL_SAFE_MULTISEND_CALL_ONLY) revert UnexpectedMultiSendCallOnly();

        IMainnetPool livePool = IMainnetPool(pool);
        IMainnetBeacon liveBeacon = IMainnetBeacon(beacon);
        address poolAdmin = livePool.admin();
        address currentImpl = liveBeacon.implementation();
        address currentOracle = livePool.priceOracle();

        if (liveBeacon.owner() != expectedSafe) revert UnexpectedBeaconOwner();
        if (poolAdmin != CANONICAL_MAINNET_POOL_ADMIN) revert UnexpectedPoolAdmin();
        if (IMainnetOwnable(poolAdmin).owner() != expectedSafe) revert UnexpectedPoolAdminOwner();
        if (multiSendCallOnly.code.length == 0) revert MissingMultiSendCallOnlyCode();
        if (newImpl.code.length == 0) revert MissingNewImplementationCode();
        if (guardedOracle.code.length == 0) revert MissingGuardedOracleCode();
        if (currentImpl != CANONICAL_MAINNET_CURRENT_IMPL) revert UnexpectedCurrentImplementation();
        if (currentOracle != CANONICAL_MAINNET_WEAK_ORACLE) revert UnexpectedCurrentOracle();
        if (newImpl == currentImpl) revert NoOpBeaconUpgrade();
        if (guardedOracle == currentOracle) revert NoOpOracleRepoint();
        if (keccak256(bytes(livePool.IMPLEMENTATION_VERSION())) != keccak256(bytes("2.15"))) {
            revert UnexpectedCurrentPoolVersion();
        }
        if (livePool.collateralToken() != CANONICAL_MAINNET_COLLATERAL_TOKEN) revert UnexpectedCollateralToken();
        if (livePool.currencyToken() != CANONICAL_MAINNET_CURRENCY_TOKEN) revert UnexpectedCurrencyToken();
        _validateImplementationShape(livePool, IMainnetPool(newImpl));
    }

    function _validateImplementationShape(IMainnetPool livePool, IMainnetPool newImpl) private view {
        if (keccak256(bytes(newImpl.IMPLEMENTATION_NAME())) != keccak256(bytes("WeightedRateERC1155CollectionPool"))) {
            revert UnexpectedImplementationName();
        }
        if (keccak256(bytes(newImpl.IMPLEMENTATION_VERSION())) != keccak256(bytes("2.16"))) {
            revert BadImplementationVersion();
        }
        address[] memory wrappers = newImpl.collateralWrappers();
        // Pool.collateralWrappers() ALWAYS returns a fixed length-3, zero-padded array
        // ([_collateralWrapper1, _collateralWrapper2, _collateralWrapper3]); it can never
        // return length 1. Pin the exact live shape: the one live ERC1155 wrapper in slot 0
        // and the remaining two slots empty.
        if (
            wrappers.length != 3 || wrappers[0] != CANONICAL_MAINNET_COLLATERAL_WRAPPER || wrappers[1] != address(0)
                || wrappers[2] != address(0)
        ) revert WrapperDrift();
        if (!_sameAddressArray(wrappers, livePool.collateralWrappers())) revert WrapperDrift();
        if (newImpl.collateralLiquidator() != CANONICAL_MAINNET_LIQUIDATOR) revert LiquidatorDrift();
        if (livePool.collateralLiquidator() != CANONICAL_MAINNET_LIQUIDATOR) revert LiquidatorDrift();
        if (newImpl.delegationRegistry() != CANONICAL_MAINNET_DELEGATE_REGISTRY_V1) revert RegistryV1Drift();
        if (livePool.delegationRegistry() != CANONICAL_MAINNET_DELEGATE_REGISTRY_V1) revert RegistryV1Drift();
        if (newImpl.delegationRegistryV2() != CANONICAL_MAINNET_DELEGATE_REGISTRY_V2) revert RegistryV2Drift();
        if (livePool.delegationRegistryV2() != CANONICAL_MAINNET_DELEGATE_REGISTRY_V2) revert RegistryV2Drift();
        if (newImpl.getERC20DepositTokenImplementation() != CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL) {
            revert DepositTokenImplementationDrift();
        }
        if (livePool.getERC20DepositTokenImplementation() != CANONICAL_MAINNET_DEPOSIT_TOKEN_IMPL) {
            revert DepositTokenImplementationDrift();
        }
        if (newImpl.liquidationGracePeriod() != CANONICAL_MAINNET_LIQUIDATION_GRACE_PERIOD) {
            revert GracePeriodDrift();
        }
        if (livePool.liquidationGracePeriod() != CANONICAL_MAINNET_LIQUIDATION_GRACE_PERIOD) {
            revert GracePeriodDrift();
        }
    }

    // The pool implementation embeds its four external libraries' ADDRESSES, not their
    // code; the impl-codehash pin therefore does NOT cover the libraries, yet they are
    // delegatecalled into pool storage and are as trust-critical as the pool. Pin the
    // deployed code of each linked library (BorrowLogic, DepositLogic, LiquidityLogic,
    // ERC20DepositTokenFactory) by reviewed address + codehash.
    function _validateLinkedLibraries() private view {
        _validateLinkedLibrary(
            _requireEnvAddress("FABRICA_MAINNET_LENDING_BORROWLOGIC"),
            _requireEnvBytes32("FABRICA_MAINNET_LENDING_BORROWLOGIC_CODEHASH")
        );
        _validateLinkedLibrary(
            _requireEnvAddress("FABRICA_MAINNET_LENDING_DEPOSITLOGIC"),
            _requireEnvBytes32("FABRICA_MAINNET_LENDING_DEPOSITLOGIC_CODEHASH")
        );
        _validateLinkedLibrary(
            _requireEnvAddress("FABRICA_MAINNET_LENDING_LIQUIDITYLOGIC"),
            _requireEnvBytes32("FABRICA_MAINNET_LENDING_LIQUIDITYLOGIC_CODEHASH")
        );
        _validateLinkedLibrary(
            _requireEnvAddress("FABRICA_MAINNET_LENDING_ERC20DEPOSITTOKENFACTORY"),
            _requireEnvBytes32("FABRICA_MAINNET_LENDING_ERC20DEPOSITTOKENFACTORY_CODEHASH")
        );
    }

    function _validateLinkedLibrary(address library_, bytes32 expectedCodehash) private view {
        if (library_.code.length == 0) revert MissingLinkedLibraryCode(library_);
        if (library_.codehash != expectedCodehash) revert UnexpectedLinkedLibraryCodehash(library_);
    }

    function _validateGuardedOracle(
        address guardedOracle,
        bytes32 expectedCodehash,
        address expectedSafe,
        address collateralToken,
        address currencyToken,
        uint256[] memory liveTokenIds,
        uint256 referenceRefreshSla,
        uint64[] memory poolRates,
        uint256[] memory expectedMaxPrices,
        uint256[] memory expectedReferencePrices
    ) private view {
        if (guardedOracle.code.length == 0) revert MissingGuardedOracleCode();
        if (vm.load(guardedOracle, ERC1967_IMPLEMENTATION_SLOT) != bytes32(0)) revert GuardedOracleMustBeDirect();
        if (vm.load(guardedOracle, ERC1967_BEACON_SLOT) != bytes32(0)) revert GuardedOracleMustBeDirect();
        if (guardedOracle.codehash != expectedCodehash) revert UnexpectedGuardedOracleCodehash();
        if (liveTokenIds.length == 0) revert TokenIdsEmpty();
        // Expected per-token appraisals (Fede's reviewed values) must be supplied 1:1 with
        // the enabled token IDs so the Safe reviews that the config is CORRECT, not merely
        // well-formed.
        if (expectedMaxPrices.length != liveTokenIds.length || expectedReferencePrices.length != liveTokenIds.length) {
            revert PolicyValueLengthMismatch();
        }

        IHardenedSimpleSignedPriceOracle oracle = IHardenedSimpleSignedPriceOracle(guardedOracle);
        (
            ,
            string memory oracleDomainName,
            string memory oracleDomainVersion,
            uint256 oracleDomainChainId,
            address oracleDomainVerifier,,
        ) = oracle.eip712Domain();

        if (keccak256(bytes(oracle.IMPLEMENTATION_VERSION())) != keccak256(bytes("1.6"))) revert BadOracleVersion();
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
        if (signer != CANONICAL_MAINNET_ORACLE_SIGNER) revert UnexpectedOracleSigner();

        IHardenedSimpleSignedPriceOracle.CollateralPolicy memory policy = oracle.collateralPolicy(collateralToken);
        if (
            !policy.configured || !policy.enabled || policy.currencyToken != currencyToken
                || policy.maxReferenceAge == 0 || policy.maxReferenceAge > MAX_REFERENCE_AGE
        ) revert BadCollateralPolicy();
        // Zero-edge guard (load-bearing, do NOT remove): the enabled generation and an
        // unstamped token's generation both default to 0, so a never-enabled market would
        // make every per-token `generation == enabledGeneration` check below a silent
        // no-op. Assert a real (post-enable) generation explicitly, independent of the
        // positional `!policy.enabled` check above.
        if (policy.enabledGeneration == 0) revert CollateralGenerationZero();
        if (referenceRefreshSla == 0 || referenceRefreshSla > policy.maxReferenceAge / 2) {
            revert ReferenceRefreshSlaTooLoose();
        }

        for (uint256 i; i < liveTokenIds.length; i++) {
            uint256 tokenId = liveTokenIds[i];
            // Strictly ascending => sorted, no duplicates, and legible to Safe reviewers.
            if (i != 0 && tokenId <= liveTokenIds[i - 1]) revert TokenIdsNotStrictlyAscending();
            // Canary: an enabled collateral token ID must never equal a pool interest-rate
            // tier. The pool's rate tiers were once mislabeled as "live token IDs"; this
            // makes that class of confusion fail closed forever.
            for (uint256 j; j < poolRates.length; j++) {
                if (tokenId == uint256(poolRates[j])) revert TokenIdCollidesWithRate(tokenId);
            }
            IHardenedSimpleSignedPriceOracle.TokenPolicy memory tokenPolicy =
                oracle.tokenPolicy(collateralToken, tokenId);
            if (
                !tokenPolicy.configured || tokenPolicy.maxPrice == 0 || tokenPolicy.referencePrice == 0
                    || tokenPolicy.referencePrice > tokenPolicy.maxPrice || tokenPolicy.referenceUpdatedAt == 0
                    || tokenPolicy.referenceUpdatedAt > block.timestamp
            ) revert BadTokenPolicy(tokenId);
            // Value pins: the on-chain hard cap + reference price must equal Fede's reviewed
            // appraisals for this token (the same numbers configured on the oracle).
            if (tokenPolicy.maxPrice != expectedMaxPrices[i]) revert UnexpectedTokenMaxPrice(tokenId);
            if (tokenPolicy.referencePrice != expectedReferencePrices[i]) {
                revert UnexpectedTokenReferencePrice(tokenId);
            }
            if (block.timestamp - tokenPolicy.referenceUpdatedAt > policy.maxReferenceAge) {
                revert ReferenceStale(tokenId);
            }
            // Generation stamp is what price() actually enforces (TokenNotEnabled on
            // mismatch, SimpleSignedPriceOracle._verifyQuote). enabledGeneration != 0 is
            // asserted above, so a never-enabled market cannot slip through this equality.
            if (oracle.tokenPolicyGeneration(collateralToken, tokenId) != policy.enabledGeneration) {
                revert TokenGenerationMismatch(tokenId);
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

    function _multiSendTx(address to, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(CALL_OPERATION, to, uint256(0), data.length, data);
    }

    function _buildMultiSendCall(address beacon, address pool, address newImpl, address guardedOracle)
        internal
        pure
        returns (bytes memory multiSendTransactions, bytes memory multiSendCall)
    {
        bytes memory upgradeCall = abi.encodeWithSelector(UPGRADE_TO_SELECTOR, newImpl);
        bytes memory repointCall = abi.encodeWithSelector(SET_PRICE_ORACLE_SELECTOR, guardedOracle);
        multiSendTransactions = bytes.concat(_multiSendTx(beacon, upgradeCall), _multiSendTx(pool, repointCall));
        multiSendCall = abi.encodeWithSelector(MULTISEND_SELECTOR, multiSendTransactions);
    }

    function _sameAddressArray(address[] memory a, address[] memory b) private pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
