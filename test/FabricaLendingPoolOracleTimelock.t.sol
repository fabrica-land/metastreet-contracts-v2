// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

interface IPoolOracleViews {
    function admin() external view returns (address);
    function priceOracle() external view returns (address);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256);
}

/// @notice Aggregator-shaped oracle: empty context ok; optional heartbeat fail-closed.
contract MockAggregatorOracle is IPriceOracle {
    uint256 internal immutable _price;
    bool internal _heartbeatDead;

    constructor(uint256 price_) {
        _price = price_;
    }

    function setHeartbeatDead(bool dead) external {
        _heartbeatDead = dead;
    }

    function price(address, address, uint256[] memory, uint256[] memory, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (_heartbeatDead) {
            revert("CheckFailed(heartbeat)");
        }
        return _price;
    }
}

contract MockERC20Metadata {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract FabricaLendingPoolOracleTimelockTest is Test {
    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle, address indexed caller);

    PoolFactory internal factory;
    UpgradeableBeacon internal beacon;
    address internal pool;
    MockAggregatorOracle internal initialOracle;
    MockAggregatorOracle internal replacementOracle;

    function setUp() public {
        initialOracle = new MockAggregatorOracle(100_000e6);
        replacementOracle = new MockAggregatorOracle(110_000e6);
        factory = PoolFactory(
            address(new ERC1967Proxy(address(new PoolFactory()), abi.encodeCall(PoolFactory.initialize, ())))
        );
        beacon = new UpgradeableBeacon(_deployPoolImplementation());
        factory.addPoolImplementation(address(beacon));
        pool = factory.createProxied(address(beacon), _poolParams(address(initialOracle)));
    }

    function test_versionIs216() public view {
        assertEq(IPoolOracleViews(pool).IMPLEMENTATION_VERSION(), "2.16");
    }

    function test_launchPath_emptyOracleContextPrices() public view {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory qtys = new uint256[](1);
        ids[0] = 42;
        qtys[0] = 1;
        uint256 p = IPoolOracleViews(pool).price(address(0xCA11), address(0xC0FFEE), ids, qtys, "");
        assertEq(p, 100_000e6);
    }

    function test_deadHeartbeat_priceReverts() public {
        initialOracle.setHeartbeatDead(true);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory qtys = new uint256[](1);
        ids[0] = 42;
        qtys[0] = 1;
        vm.expectRevert(bytes("CheckFailed(heartbeat)"));
        IPoolOracleViews(pool).price(address(0xCA11), address(0xC0FFEE), ids, qtys, "");
    }

    function test_adminCanSetPriceOracle() public {
        vm.expectEmit(true, true, true, true, pool);
        emit PriceOracleUpdated(address(initialOracle), address(replacementOracle), address(factory));
        vm.prank(address(factory));
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
        assertEq(IPoolOracleViews(pool).priceOracle(), address(replacementOracle));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory qtys = new uint256[](1);
        ids[0] = 1;
        qtys[0] = 1;
        assertEq(IPoolOracleViews(pool).price(address(0), address(0), ids, qtys, ""), 110_000e6);
    }

    function test_randomCallerCannotSet() public {
        address caller = makeAddr("random");
        vm.prank(caller);
        vm.expectRevert(WeightedRateERC1155CollectionPool.InvalidPriceOracleUpdater.selector);
        IOracleRepoint(pool).setPriceOracle(address(replacementOracle));
    }

    function test_rejectsEoaOracle() public {
        address eoa = makeAddr("eoa-oracle");
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ExternalPriceOracle.InvalidPriceOracle.selector, eoa));
        IOracleRepoint(pool).setPriceOracle(eoa);
    }

    function test_rejectsUnchangedOracle() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(ExternalPriceOracle.PriceOracleUnchanged.selector, address(initialOracle))
        );
        IOracleRepoint(pool).setPriceOracle(address(initialOracle));
    }

    function test_fallbackRejectsUnknownSelector() public {
        (bool ok, bytes memory data) = pool.call(abi.encodeWithSelector(bytes4(0x12345678)));
        assertFalse(ok);
        assertEq(bytes4(data), bytes4(keccak256("InvalidParameters()")));
    }

    function test_createProxiedLaunchPath_beaconMode() public {
        address second = factory.createProxied(address(beacon), _poolParams(address(replacementOracle)));
        assertEq(IPoolOracleViews(second).priceOracle(), address(replacementOracle));
        assertEq(IPoolOracleViews(second).admin(), address(factory));
    }

    function _poolParams(address priceOracle) internal returns (bytes memory) {
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(0xCA11A7E);
        uint64[] memory durations = new uint64[](1);
        durations[0] = 30 days;
        uint64[] memory rates = new uint64[](1);
        rates[0] = 1;
        return abi.encode(collateralTokens, address(new MockERC20Metadata()), priceOracle, durations, rates);
    }

    function _deployPoolImplementation() internal returns (address) {
        address liquidator = address(new MockCollateralLiquidator());
        address depositImpl = address(new ERC20DepositTokenImplementation());
        address wrapper = address(new ERC1155CollateralWrapper());
        address[] memory wrappers = new address[](1);
        wrappers[0] = wrapper;
        return address(
            new WeightedRateERC1155CollectionPool(
                liquidator,
                address(0x00000000000076A84feF008CDAbe6409d2FE638B),
                address(0x00000000000000447e69651d841bD8D104Bed493),
                depositImpl,
                wrappers,
                15 days
            )
        );
    }
}
