// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {PoolFactory} from "fabrica-lending-pools/PoolFactory.sol";
import {IPriceOracle} from "fabrica-lending-pools/interfaces/IPriceOracle.sol";
import {ExternalPriceOracle} from "fabrica-lending-pools/oracle/ExternalPriceOracle.sol";
import {ERC20DepositTokenImplementation} from "fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import {
    WeightedRateERC1155CollectionPool
} from "fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";
import {ERC1155CollateralWrapper} from "fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";

import "./concretes/MockCollateralLiquidator.sol";

interface IOracleRepoint {
    function setPriceOracle(address newOracle) external;
}

interface ILiveUpgradeableBeacon {
    function implementation() external view returns (address);
    function owner() external view returns (address);
    function upgradeTo(address newImplementation) external;
}

interface ILivePool {
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function priceOracle() external view returns (address);
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256);
}

contract MockERC20Metadata {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MockPriceOracle is IPriceOracle {
    uint256 internal immutable price_;

    constructor(uint256 price__) {
        price_ = price__;
    }

    function price(address, address, uint256[] memory, uint256[] memory, bytes calldata)
        external
        view
        returns (uint256)
    {
        return price_;
    }
}

contract WrongShapeOracle {
    function notPrice() external pure returns (uint256) {
        return 1;
    }
}

contract NonOwnablePoolAdmin {
    function createPool(address beacon, bytes memory params) external returns (address) {
        return address(new BeaconProxy(beacon, abi.encodeWithSignature("initialize(bytes)", params)));
    }
}

contract FabricaLendingPoolOracleRepointTest is Test {
    bytes32 internal constant PRICE_ORACLE_LOCATION =
        0x5cc3a0ef4fb602d81e01a142e768b704108e3b2e96852939d75763e011a39b00;
    address internal constant CANONICAL_FABRICA_SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    address internal constant MAINNET_POOL = 0x221014c0b6871f3F0d57F262ae6B5b6CD2901456;
    address internal constant MAINNET_BEACON = 0x30E9A2082E297a2E18615224A6146f6c73F7b7A6;
    address internal constant MAINNET_WEAK_ORACLE = 0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5;
    address internal constant MAINNET_FACTORY_ADMIN = 0x759991Bf617BAc3728983bF03Fb4d744C51F2A4F;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_LIQUIDATOR = 0xa24DC4f04d1AC9B41dF0F7c2C772A9c0192D9C3B;
    address internal constant MAINNET_DELEGATE_REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    address internal constant MAINNET_DELEGATE_REGISTRY_V2 = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant MAINNET_DEPOSIT_TOKEN_IMPL = 0xa8920d5dc52eEDD33570FDbAC21d02b7e8EE9634;
    address internal constant MAINNET_WRAPPER = 0x05489aC114fBaaedeE4a49B67fCc5666C951E552;
    address internal constant DUMMY_COLLATERAL_TOKEN = address(0xCA11A7E);
    bytes4 internal constant INVALID_PARAMETERS_SELECTOR = bytes4(keccak256("InvalidParameters()"));
    uint64 internal constant MAINNET_LIQUIDATION_GRACE_PERIOD = 15 days;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_597_121;

    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle, address indexed caller);

    PoolFactory internal factory;
    UpgradeableBeacon internal beacon;
    address internal pool;
    MockPriceOracle internal initialOracle;
    MockPriceOracle internal replacementOracle;

    function setUp() public {
        initialOracle = new MockPriceOracle(100);
        replacementOracle = new MockPriceOracle(200);
        factory = PoolFactory(
            address(new ERC1967Proxy(address(new PoolFactory()), abi.encodeCall(PoolFactory.initialize, ())))
        );
        beacon = new UpgradeableBeacon(_deployPoolImplementation());
        factory.addPoolImplementation(address(beacon));
        pool = factory.createProxied(address(beacon), _poolParams(address(initialOracle)));
    }

    function test_adminCanRepointExistingOracleSlot() public {
        vm.expectEmit(true, true, true, true, pool);
        emit PriceOracleUpdated(address(initialOracle), address(replacementOracle), address(factory));
        vm.prank(address(factory));
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
        assertEq(ILivePool(pool).priceOracle(), address(replacementOracle), "oracle getter");
        assertEq(
            address(uint160(uint256(vm.load(pool, PRICE_ORACLE_LOCATION)))), address(replacementOracle), "oracle slot"
        );
    }

    function test_canonicalSafeCanRepointExistingOracleSlot() public {
        factory.transferOwnership(CANONICAL_FABRICA_SAFE);
        vm.prank(CANONICAL_FABRICA_SAFE);
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
        assertEq(ILivePool(pool).priceOracle(), address(replacementOracle), "oracle getter");
    }

    function test_randomCallerCannotRepoint() public {
        address caller = makeAddr("random-caller");
        vm.prank(caller);
        vm.expectRevert(WeightedRateERC1155CollectionPool.InvalidPriceOracleUpdater.selector);
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
    }

    function test_fallbackRejectsEmptyAndUnknownSelectors() public {
        (bool ok, bytes memory data) = pool.call("");
        assertFalse(ok, "empty calldata reverted");
        _assertRevertSelector(data, INVALID_PARAMETERS_SELECTOR);
        (ok, data) = pool.call(abi.encodeWithSelector(bytes4(0x12345678), address(replacementOracle)));
        assertFalse(ok, "unknown selector reverted");
        _assertRevertSelector(data, INVALID_PARAMETERS_SELECTOR);
    }

    function test_nonOwnableAdminOwnerLookupFailsClosed() public {
        NonOwnablePoolAdmin admin = new NonOwnablePoolAdmin();
        address adminPool = admin.createPool(address(beacon), _poolParams(address(initialOracle)));
        assertEq(ILivePool(adminPool).admin(), address(admin), "non-ownable admin");
        vm.prank(CANONICAL_FABRICA_SAFE);
        vm.expectRevert(WeightedRateERC1155CollectionPool.InvalidPriceOracleUpdater.selector);
        IOracleRepoint(adminPool).setPriceOracle(address(replacementOracle));
    }

    function test_repointRejectsZeroNoCodeWrongShapeAndUnchangedOracle() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ExternalPriceOracle.InvalidPriceOracle.selector, address(0)));
        IOracleRepoint(pool).setPriceOracle(address(0));
        address noCode = makeAddr("no-code-oracle");
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ExternalPriceOracle.InvalidPriceOracle.selector, noCode));
        IOracleRepoint(pool).setPriceOracle(noCode);
        address wrongShape = address(new WrongShapeOracle());
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ExternalPriceOracle.InvalidPriceOracle.selector, wrongShape));
        IOracleRepoint(pool).setPriceOracle(wrongShape);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(ExternalPriceOracle.PriceOracleUnchanged.selector, address(initialOracle))
        );
        IOracleRepoint(pool).setPriceOracle(address(initialOracle));
    }

    function test_repointChangesPoolPriceRoute() public {
        assertEq(_poolPrice(), 100, "initial price");
        vm.prank(address(factory));
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
        assertEq(_poolPrice(), 200, "replacement price");
    }

    function test_mainnetFork_safeUpgradeAndRepointPreservesPoolState() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        assertGt(MAINNET_POOL.code.length, 0, "mainnet pool code required");
        ILivePool livePool = ILivePool(MAINNET_POOL);
        ILiveUpgradeableBeacon liveBeacon = ILiveUpgradeableBeacon(MAINNET_BEACON);
        bytes32 slotBefore = vm.load(MAINNET_POOL, PRICE_ORACLE_LOCATION);
        address implementationBefore = liveBeacon.implementation();
        address ownerBefore = liveBeacon.owner();
        address adminBefore = livePool.admin();
        assertEq(livePool.priceOracle(), MAINNET_WEAK_ORACLE, "weak oracle prestate");
        assertEq(address(uint160(uint256(slotBefore))), MAINNET_WEAK_ORACLE, "slot prestate");
        assertEq(ownerBefore, CANONICAL_FABRICA_SAFE, "beacon owner safe");
        assertEq(adminBefore, MAINNET_FACTORY_ADMIN, "pool admin");

        WeightedRateERC1155CollectionPool newImplementation = _deployMainnetShapedImplementation();
        MockPriceOracle newOracle = new MockPriceOracle(123456789);
        vm.prank(CANONICAL_FABRICA_SAFE);
        liveBeacon.upgradeTo(address(newImplementation));
        assertEq(liveBeacon.implementation(), address(newImplementation), "beacon implementation");
        assertEq(livePool.IMPLEMENTATION_VERSION(), "2.16", "version");
        assertEq(vm.load(MAINNET_POOL, PRICE_ORACLE_LOCATION), slotBefore, "oracle slot preserved before repoint");
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(WeightedRateERC1155CollectionPool.InvalidPriceOracleUpdater.selector);
        IOracleRepoint(MAINNET_POOL).setPriceOracle(address(newOracle));
        vm.prank(CANONICAL_FABRICA_SAFE);
        IOracleRepoint(MAINNET_POOL).setPriceOracle(address(newOracle));
        assertEq(livePool.priceOracle(), address(newOracle), "oracle repointed");
        assertEq(
            address(uint160(uint256(vm.load(MAINNET_POOL, PRICE_ORACLE_LOCATION)))),
            address(newOracle),
            "slot poststate"
        );
        assertEq(_livePoolPrice(livePool), 123456789, "pool routes through new oracle");
        assertEq(livePool.admin(), adminBefore, "admin preserved");
        assertEq(liveBeacon.owner(), ownerBefore, "owner preserved");
        assertTrue(implementationBefore != address(0), "old implementation nonzero");
    }

    function _deployPoolImplementation() internal returns (address) {
        ERC20DepositTokenImplementation depositTokenImpl = new ERC20DepositTokenImplementation();
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        return address(
            new WeightedRateERC1155CollectionPool(
                address(new MockCollateralLiquidator()),
                makeAddr("delegateRegistryV1"),
                makeAddr("delegateRegistryV2"),
                address(depositTokenImpl),
                wrappers,
                7 days
            )
        );
    }

    function _deployMainnetShapedImplementation() internal returns (WeightedRateERC1155CollectionPool) {
        address[] memory wrappers = new address[](1);
        wrappers[0] = MAINNET_WRAPPER;
        return new WeightedRateERC1155CollectionPool(
            MAINNET_LIQUIDATOR,
            MAINNET_DELEGATE_REGISTRY_V1,
            MAINNET_DELEGATE_REGISTRY_V2,
            MAINNET_DEPOSIT_TOKEN_IMPL,
            wrappers,
            MAINNET_LIQUIDATION_GRACE_PERIOD
        );
    }

    function _poolParams(address priceOracle) internal returns (bytes memory) {
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = makeAddr("collateralToken");
        uint64[] memory durations = new uint64[](1);
        durations[0] = 30 days;
        uint64[] memory rates = new uint64[](1);
        rates[0] = 1;
        return abi.encode(collateralTokens, address(new MockERC20Metadata()), priceOracle, durations, rates);
    }

    function _poolPrice() internal view returns (uint256) {
        return _livePoolPrice(ILivePool(pool));
    }

    function _livePoolPrice(ILivePool livePool) internal view returns (uint256) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1;
        return livePool.price(DUMMY_COLLATERAL_TOKEN, MAINNET_USDC, tokenIds, quantities, "");
    }

    function _assertRevertSelector(bytes memory data, bytes4 selector) internal pure {
        assertEq(data.length, 4, "revert data length");
        assertEq(bytes4(data), selector, "revert selector");
    }
}
