// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import {SimpleSignedPriceOracle} from "fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";
import {
    WeightedRateERC1155CollectionPool
} from "fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";
import "../script/FabricaLendingPoolMainnetOracleRepointPacket.s.sol";

/**
 * @title End-to-end run() coverage for the mainnet oracle-repoint packet
 *
 * Before ENG-3695's packet hardening, the packet's `run()` had ZERO test
 * coverage — only the pure `_buildMultiSendCall` helper was exercised — so the
 * `_validateImplementationShape` wrapper-arity bug (asserting a length-1
 * `collateralWrappers()` the getter can never return) shipped through review.
 *
 * This runs the FULL `run()` against a mainnet fork with a real, freshly built
 * 2.16 implementation and a real, fully configured direct 1.6 oracle, asserting
 * the packet emits the Safe calldata on the happy path and fails closed on each
 * hardening invariant.
 *
 * All scenarios live in ONE test function on purpose: `run()` reads process
 * environment via `vm.envUint`/`vm.envAddress`, and forge executes test
 * FUNCTIONS in parallel — so `vm.setEnv` from one function would race another.
 * Kept sequential here, with `vm.snapshotState`/`revertToState` isolating the
 * scenarios that mutate on-chain state.
 */
contract FabricaLendingPoolOracleRepointPacketRunTest is Test {
    address internal constant BEACON = 0x30E9A2082E297a2E18615224A6146f6c73F7b7A6;
    address internal constant POOL = 0x221014c0b6871f3F0d57F262ae6B5b6CD2901456;
    address internal constant SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    address internal constant MULTISEND = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761;
    address internal constant COLLATERAL = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant LIQUIDATOR = 0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B;
    address internal constant REG_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    address internal constant REG_V2 = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant DEP_TOKEN_IMPL = 0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634;
    address internal constant WRAPPER = 0x05489aC114fBaaedeE4a49B67fCc5666C951E552;
    address internal constant SIGNER = 0xC888f5e3Dd4FBeB37f6e1bA6FA68c83aB0cf7B2c;
    uint64 internal constant GRACE = 1_296_000;

    // Live mainnet linked-library set (recovered from the 2.15 impl); present on the fork.
    address internal constant LIB_BORROWLOGIC = 0x74FC5ef1917D28b11626298F5B403b0c5362FEBf;
    address internal constant LIB_DEPOSITLOGIC = 0xf921BC503Aaf69a95Cb532A1D5084cECD47a2cF1;
    address internal constant LIB_LIQUIDITYLOGIC = 0x62643040564e920306C8314E8CF0a0E9a13db29B;
    address internal constant LIB_ERC20FACTORY = 0xD39789733F2A93405CFBb76a60C51Ebf612738b4;

    // A live pool interest-rate tier (pool.rates()[0]) — must never be a valid token ID.
    uint256 internal constant RATE_TIER_0 = 1_585_489_599;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    bool internal forked;
    FabricaLendingPoolMainnetOracleRepointPacketScript internal packet;
    SimpleSignedPriceOracle internal oracle;
    address internal newImpl;
    uint256[] internal tokenIds;
    uint256[] internal maxPrices;
    uint256[] internal refPrices;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("MAINNET_RPC_URL not set; skipping packet run() fork suite");
            return;
        }
        forked = true;
        // Fork at latest, not a pinned block: the cutover prestate (beacon impl 0x623Ce6,
        // pool 2.15, weak oracle 0x3ed9) is unchanged on mainnet until the Safe executes,
        // and latest avoids requiring an archive node.
        vm.createSelectFork(rpc);
        packet = new FabricaLendingPoolMainnetOracleRepointPacketScript();

        newImpl = address(
            new WeightedRateERC1155CollectionPool(LIQUIDATOR, REG_V1, REG_V2, DEP_TOKEN_IMPL, _wrappers(), GRACE)
        );

        // Real collateral parcel IDs (Fede-style): strictly ascending, none equal to a
        // pool rate tier. Appraisals: referencePrice <= maxPrice.
        tokenIds = new uint256[](3);
        tokenIds[0] = 1_000_000_000_000_000_001;
        tokenIds[1] = 2_000_000_000_000_000_002;
        tokenIds[2] = 3_000_000_000_000_000_003;
        maxPrices = new uint256[](3);
        maxPrices[0] = 100_000_000;
        maxPrices[1] = 200_000_000;
        maxPrices[2] = 300_000_000;
        refPrices = new uint256[](3);
        refPrices[0] = 50_000_000;
        refPrices[1] = 150_000_000;
        refPrices[2] = 250_000_000;

        oracle = new SimpleSignedPriceOracle("All US Land");
        oracle.setSigner(COLLATERAL, SIGNER);
        // maxReferenceAge 30d so SLA 7d <= maxReferenceAge/2.
        oracle.setCollateralPolicy(COLLATERAL, USDC, 3600, 1800, 30 days);
        for (uint256 i; i < tokenIds.length; i++) {
            oracle.setTokenPolicy(COLLATERAL, tokenIds[i], maxPrices[i], refPrices[i], uint64(block.timestamp), 1000);
        }
        oracle.setCollateralEnabled(COLLATERAL, true, tokenIds);
        oracle.transferOwnership(SAFE);
        vm.prank(SAFE);
        oracle.acceptOwnership();
    }

    function test_run_hardeningScenarios() public {
        if (!forked) return;

        // --- Happy path: full run() emits the Safe calldata. This also exercises the
        // fixed length-3 wrapper canary; the pre-fix `!= 1` assertion would revert here.
        _setEnv();
        packet.run();

        // Wrapper getter shape regression: fixed length-3 zero-padded, and accepted.
        address[] memory w = WeightedRateERC1155CollectionPool(payable(newImpl)).collateralWrappers();
        assertEq(w.length, 3, "getter returns fixed length-3");
        assertEq(w[0], WRAPPER, "slot0 wrapper");
        assertEq(w[1], address(0), "slot1 empty");
        assertEq(w[2], address(0), "slot2 empty");

        // --- Appraisal arrays must be 1:1 with the token IDs.
        _setEnv();
        vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", string.concat(_csv(maxPrices), ",999"));
        vm.expectRevert(PolicyValueLengthMismatch.selector);
        packet.run();

        // --- On-chain maxPrice must equal Fede's reviewed appraisal.
        _setEnv();
        uint256[] memory badMax = new uint256[](3);
        badMax[0] = maxPrices[0];
        badMax[1] = maxPrices[1] + 1;
        badMax[2] = maxPrices[2];
        vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", _csv(badMax));
        vm.expectRevert(abi.encodeWithSelector(UnexpectedTokenMaxPrice.selector, tokenIds[1]));
        packet.run();

        // --- Token IDs must be strictly ascending (sorted + unique). Swap IDs AND their
        // parallel appraisals so element 0 passes its value pin and the ordering violation
        // at element 1 is what trips.
        _setEnv();
        uint256[] memory swapIds = new uint256[](3);
        uint256[] memory swapMax = new uint256[](3);
        uint256[] memory swapRef = new uint256[](3);
        swapIds[0] = tokenIds[1];
        swapIds[1] = tokenIds[0];
        swapIds[2] = tokenIds[2];
        swapMax[0] = maxPrices[1];
        swapMax[1] = maxPrices[0];
        swapMax[2] = maxPrices[2];
        swapRef[0] = refPrices[1];
        swapRef[1] = refPrices[0];
        swapRef[2] = refPrices[2];
        vm.setEnv("FABRICA_MAINNET_LIVE_TOKEN_IDS", _csv(swapIds));
        vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", _csv(swapMax));
        vm.setEnv("FABRICA_MAINNET_TOKEN_REFERENCE_PRICES", _csv(swapRef));
        vm.expectRevert(TokenIdsNotStrictlyAscending.selector);
        packet.run();

        // --- Rate-tier collision canary: an enabled ID equal to pool.rates() fails closed.
        {
            uint256 snap = vm.snapshotState();
            uint256[] memory rateIds = new uint256[](1);
            rateIds[0] = RATE_TIER_0;
            vm.startPrank(SAFE);
            oracle.setTokenPolicy(COLLATERAL, RATE_TIER_0, 100_000_000, 50_000_000, uint64(block.timestamp), 1000);
            oracle.setCollateralEnabled(COLLATERAL, true, rateIds);
            vm.stopPrank();
            _setEnv();
            vm.setEnv("FABRICA_MAINNET_LIVE_TOKEN_IDS", vm.toString(RATE_TIER_0));
            vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", "100000000");
            vm.setEnv("FABRICA_MAINNET_TOKEN_REFERENCE_PRICES", "50000000");
            vm.expectRevert(abi.encodeWithSelector(TokenIdCollidesWithRate.selector, RATE_TIER_0));
            packet.run();
            vm.revertToState(snap);
        }

        // --- Generation stamp: a configured-but-never-enabled token (generation 0) must not
        // pass even though its policy is well-formed and fresh.
        {
            uint256 snap = vm.snapshotState();
            uint256 extra = 4_000_000_000_000_000_004;
            vm.prank(SAFE);
            oracle.setTokenPolicy(COLLATERAL, extra, 400_000_000, 200_000_000, uint64(block.timestamp), 1000);
            uint256[] memory ids4 = new uint256[](4);
            uint256[] memory max4 = new uint256[](4);
            uint256[] memory ref4 = new uint256[](4);
            for (uint256 i; i < 3; i++) {
                ids4[i] = tokenIds[i];
                max4[i] = maxPrices[i];
                ref4[i] = refPrices[i];
            }
            ids4[3] = extra;
            max4[3] = 400_000_000;
            ref4[3] = 200_000_000;
            _setEnv();
            vm.setEnv("FABRICA_MAINNET_LIVE_TOKEN_IDS", _csv(ids4));
            vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", _csv(max4));
            vm.setEnv("FABRICA_MAINNET_TOKEN_REFERENCE_PRICES", _csv(ref4));
            vm.expectRevert(abi.encodeWithSelector(TokenGenerationMismatch.selector, extra));
            packet.run();
            vm.revertToState(snap);
        }

        // --- GuardedOracleMustBeDirect (1/2): a set ERC1967 implementation slot => proxied.
        {
            uint256 snap = vm.snapshotState();
            _setEnv();
            vm.store(address(oracle), ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(0xDEAD)));
            vm.expectRevert(GuardedOracleMustBeDirect.selector);
            packet.run();
            vm.revertToState(snap);
        }

        // --- GuardedOracleMustBeDirect (2/2): a set ERC1967 beacon slot => beacon proxy.
        {
            uint256 snap = vm.snapshotState();
            _setEnv();
            vm.store(address(oracle), ERC1967_BEACON_SLOT, bytes32(uint256(0xBEEF)));
            vm.expectRevert(GuardedOracleMustBeDirect.selector);
            packet.run();
            vm.revertToState(snap);
        }
    }

    function _wrappers() internal pure returns (address[] memory w) {
        w = new address[](1);
        w[0] = WRAPPER;
    }

    function _setEnv() internal {
        vm.setEnv("FABRICA_MAINNET_LENDING_BEACON", vm.toString(BEACON));
        vm.setEnv("FABRICA_MAINNET_LENDING_POOL", vm.toString(POOL));
        vm.setEnv("FABRICA_MAINNET_LENDING_SAFE", vm.toString(SAFE));
        vm.setEnv("FABRICA_MAINNET_SAFE_MULTISEND_CALL_ONLY", vm.toString(MULTISEND));
        vm.setEnv("FABRICA_MAINNET_LENDING_NEW_IMPL", vm.toString(newImpl));
        vm.setEnv("FABRICA_MAINNET_LENDING_NEW_IMPL_CODEHASH", vm.toString(newImpl.codehash));
        vm.setEnv("FABRICA_MAINNET_GUARDED_PRICE_ORACLE", vm.toString(address(oracle)));
        vm.setEnv("FABRICA_MAINNET_GUARDED_PRICE_ORACLE_CODEHASH", vm.toString(address(oracle).codehash));
        vm.setEnv("FABRICA_MAINNET_LENDING_BORROWLOGIC", vm.toString(LIB_BORROWLOGIC));
        vm.setEnv("FABRICA_MAINNET_LENDING_BORROWLOGIC_CODEHASH", vm.toString(LIB_BORROWLOGIC.codehash));
        vm.setEnv("FABRICA_MAINNET_LENDING_DEPOSITLOGIC", vm.toString(LIB_DEPOSITLOGIC));
        vm.setEnv("FABRICA_MAINNET_LENDING_DEPOSITLOGIC_CODEHASH", vm.toString(LIB_DEPOSITLOGIC.codehash));
        vm.setEnv("FABRICA_MAINNET_LENDING_LIQUIDITYLOGIC", vm.toString(LIB_LIQUIDITYLOGIC));
        vm.setEnv("FABRICA_MAINNET_LENDING_LIQUIDITYLOGIC_CODEHASH", vm.toString(LIB_LIQUIDITYLOGIC.codehash));
        vm.setEnv("FABRICA_MAINNET_LENDING_ERC20DEPOSITTOKENFACTORY", vm.toString(LIB_ERC20FACTORY));
        vm.setEnv("FABRICA_MAINNET_LENDING_ERC20DEPOSITTOKENFACTORY_CODEHASH", vm.toString(LIB_ERC20FACTORY.codehash));
        vm.setEnv("FABRICA_MAINNET_LIVE_TOKEN_IDS", _csv(tokenIds));
        vm.setEnv("FABRICA_MAINNET_TOKEN_MAX_PRICES", _csv(maxPrices));
        vm.setEnv("FABRICA_MAINNET_TOKEN_REFERENCE_PRICES", _csv(refPrices));
        vm.setEnv("FABRICA_MAINNET_REFERENCE_REFRESH_SLA_SECONDS", "604800");
    }

    function _csv(uint256[] memory xs) internal pure returns (string memory out) {
        out = vm.toString(xs[0]);
        for (uint256 i = 1; i < xs.length; i++) {
            out = string.concat(out, ",", vm.toString(xs[i]));
        }
    }
}
