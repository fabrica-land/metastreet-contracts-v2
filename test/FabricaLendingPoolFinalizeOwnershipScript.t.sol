// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {PoolFactory} from "fabrica-lending-pools/PoolFactory.sol";
import {
    EnglishAuctionCollateralLiquidator
} from "fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import {ERC20DepositTokenImplementation} from "fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import {SimpleSignedPriceOracle} from "fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";
import {
    WeightedRateERC1155CollectionPool
} from "fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";
import {ERC1155CollateralWrapper} from "fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";

import "../script/FabricaLendingPoolFinalizeOwnership.s.sol";

contract MockOracleOwner is Ownable2Step {
    string internal name_;
    string internal eip712Version_;
    string internal domainVersion_;
    uint256 internal domainChainId_;
    address internal verifyingContract_;

    constructor(
        address owner_,
        string memory name__,
        string memory eip712Version__,
        string memory domainVersion__,
        uint256 domainChainId__,
        address verifyingContract__
    ) {
        name_ = name__;
        eip712Version_ = eip712Version__;
        domainVersion_ = domainVersion__;
        domainChainId_ = domainChainId__;
        verifyingContract_ = verifyingContract__;
        _transferOwnership(owner_);
    }

    function DOMAIN_VERSION() external view returns (string memory) {
        return domainVersion_;
    }

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
        )
    {
        address resolvedVerifyingContract = verifyingContract_ == address(0) ? address(this) : verifyingContract_;
        return (hex"0f", name_, eip712Version_, domainChainId_, resolvedVerifyingContract, bytes32(0), new uint256[](0));
    }
}

contract MockERC20Metadata {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract FinalizeOwnershipScriptHarness is FabricaLendingPoolFinalizeOwnershipScript {
    function requireNonZero(string memory name, address value) external pure {
        _requireNonZero(name, value);
    }

    function validateOwnerConfig(address expectedCurrentOwner, address finalOwner, address broadcaster) external view {
        _validateOwnerConfig(expectedCurrentOwner, finalOwner, broadcaster);
    }

    function validateTargets(
        address factory,
        address factoryImpl,
        address beacon,
        address poolImpl,
        address pool,
        address oracle,
        address oracleImpl,
        string memory oracleDomainName
    ) external view {
        _validateTargets(factory, factoryImpl, beacon, poolImpl, pool, oracle, oracleImpl, oracleDomainName);
    }

    function validateOwner(string memory target, address actual, address expectedCurrentOwner, address finalOwner)
        external
        pure
    {
        _validateOwner(target, actual, expectedCurrentOwner, finalOwner);
    }

    function validateOracleOwner(ISimpleSignedPriceOracleOwner oracle, address expectedCurrentOwner, address finalOwner)
        external
        view
    {
        _validateOracleOwner(oracle, expectedCurrentOwner, finalOwner);
    }

    function handoff(
        IPoolFactoryOwner factory,
        IUpgradeableBeaconOwner beacon,
        ISimpleSignedPriceOracleOwner oracle,
        address expectedCurrentOwner,
        address finalOwner
    ) external {
        _handoff(factory, beacon, oracle, expectedCurrentOwner, finalOwner);
    }
}

contract FabricaLendingPoolFinalizeOwnershipScriptTest is Test {
    address internal constant SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    string internal constant ORACLE_DOMAIN_NAME = "Correct Mainnet Pool";
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    PoolFactory internal factory;
    PoolFactory internal factoryImpl;
    UpgradeableBeacon internal beacon;
    address internal poolImpl;
    address internal pool;
    SimpleSignedPriceOracle internal oracle;
    SimpleSignedPriceOracle internal oracleImpl;
    FinalizeOwnershipScriptHarness internal script;

    function setUp() public {
        vm.chainId(1);
        vm.etch(SAFE, hex"6000");
        script = new FinalizeOwnershipScriptHarness();
        _deployActualTopology(address(this));
        _setEnv(address(this), SAFE);
    }

    function test_run_starts_safe_handoff() public {
        script.run();
        assertEq(factory.owner(), SAFE, "factory owner");
        assertEq(beacon.owner(), SAFE, "beacon owner");
        assertEq(oracle.owner(), address(this), "oracle owner awaits Safe accept");
        assertEq(oracle.pendingOwner(), SAFE, "oracle pending owner");
    }

    function test_run_resumes_after_factory_already_transferred() public {
        factory.transferOwnership(SAFE);
        script.run();
        assertEq(factory.owner(), SAFE, "factory owner");
        assertEq(beacon.owner(), SAFE, "beacon owner");
        assertEq(oracle.pendingOwner(), SAFE, "oracle pending owner");
    }

    function test_run_resumes_with_oracle_pending_safe() public {
        oracle.transferOwnership(SAFE);
        script.run();
        assertEq(oracle.owner(), address(this), "oracle owner awaits Safe accept");
        assertEq(oracle.pendingOwner(), SAFE, "oracle pending owner");
    }

    function test_run_accepts_oracle_already_owned_by_safe() public {
        oracle.transferOwnership(SAFE);
        vm.prank(SAFE);
        oracle.acceptOwnership();
        script.run();
        assertEq(oracle.owner(), SAFE, "oracle owner");
        assertEq(oracle.pendingOwner(), address(0), "oracle pending owner");
    }

    function test_run_rejects_non_mainnet_before_broadcast() public {
        vm.chainId(11155111);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaLendingPoolFinalizeOwnershipScript.ExpectedMainnet.selector, 11155111)
        );
        script.run();
    }

    function test_rejects_non_canonical_final_owner() public {
        address wrongSafe = makeAddr("wrongSafe");
        vm.etch(wrongSafe, hex"6000");
        vm.expectRevert(
            abi.encodeWithSelector(FabricaLendingPoolFinalizeOwnershipScript.NonCanonicalFinalOwner.selector, wrongSafe)
        );
        script.validateOwnerConfig(address(this), wrongSafe, address(this));
    }

    function test_rejects_expected_owner_must_broadcast() public {
        address expectedCurrentOwner = makeAddr("expectedCurrentOwner");
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.ExpectedOwnerMustBroadcast.selector,
                expectedCurrentOwner,
                address(this)
            )
        );
        script.validateOwnerConfig(expectedCurrentOwner, SAFE, address(this));
    }

    function test_rejects_final_owner_equal_to_deployer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.FinalOwnerMustDifferFromCurrentOwner.selector, SAFE
            )
        );
        script.validateOwnerConfig(SAFE, SAFE, SAFE);
    }

    function test_rejects_zero_address() public {
        vm.expectRevert(
            abi.encodeWithSelector(FabricaLendingPoolFinalizeOwnershipScript.ZeroAddress.selector, "factory")
        );
        script.requireNonZero("factory", address(0));
    }

    function test_rejects_non_contract_pool() public {
        address nonContractPool = makeAddr("nonContractPool");
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.NotContract.selector, "pool", nonContractPool
            )
        );
        _validateTargetsForPool(
            nonContractPool,
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(oracle),
            address(oracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_wrong_factory_identity() public {
        address wrongImpl = address(new PoolFactory());
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedFactoryImplementation.selector,
                address(factoryImpl),
                wrongImpl
            )
        );
        _validateTargets(wrongImpl, address(beacon), poolImpl, address(oracle), address(oracleImpl), ORACLE_DOMAIN_NAME);
    }

    function test_rejects_wrong_beacon_identity() public {
        address wrongPoolImpl = address(new PoolFactory());
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedBeaconImplementation.selector,
                poolImpl,
                wrongPoolImpl
            )
        );
        _validateTargets(
            address(factoryImpl),
            address(beacon),
            wrongPoolImpl,
            address(oracle),
            address(oracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_wrong_oracle_implementation() public {
        address wrongOracleImpl = address(new SimpleSignedPriceOracle(ORACLE_DOMAIN_NAME));
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleImplementation.selector,
                address(oracleImpl),
                wrongOracleImpl
            )
        );
        _validateTargets(
            address(factoryImpl), address(beacon), poolImpl, address(oracle), wrongOracleImpl, ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_oracle_not_bound_to_pool() public {
        SimpleSignedPriceOracle lookalikeImpl = new SimpleSignedPriceOracle(ORACLE_DOMAIN_NAME);
        SimpleSignedPriceOracle lookalikeOracle = SimpleSignedPriceOracle(
            address(
                new ERC1967Proxy(
                    address(lookalikeImpl), abi.encodeCall(SimpleSignedPriceOracle.initialize, (address(this)))
                )
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedPoolOracle.selector,
                address(oracle),
                address(lookalikeOracle)
            )
        );
        _validateTargets(
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(lookalikeOracle),
            address(lookalikeImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_pool_not_registered_by_factory() public {
        address unregisteredPool = _createPoolFromBeacon(address(beacon), address(oracle));
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.PoolNotRegistered.selector, address(factory), unregisteredPool
            )
        );
        _validateTargetsForPool(
            unregisteredPool,
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(oracle),
            address(oracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_pool_created_from_wrong_beacon() public {
        UpgradeableBeacon wrongBeacon = new UpgradeableBeacon(poolImpl);
        factory.addPoolImplementation(address(wrongBeacon));
        address wrongBeaconPool = factory.createProxied(address(wrongBeacon), _poolParams(address(oracle)));
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedPoolBeacon.selector,
                address(wrongBeacon),
                address(beacon)
            )
        );
        _validateTargetsForPool(
            wrongBeaconPool,
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(oracle),
            address(oracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_wrong_oracle_domain_name() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleDomainName.selector,
                ORACLE_DOMAIN_NAME,
                "Wrong Pool"
            )
        );
        _validateTargets(
            address(factoryImpl), address(beacon), poolImpl, address(oracle), address(oracleImpl), "Wrong Pool"
        );
    }

    function test_rejects_wrong_oracle_domain_chain_id() public {
        _expectMockOracleTargetRevert(
            ORACLE_DOMAIN_NAME,
            "1.2",
            "1.2",
            11155111,
            address(0),
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleDomainChainId.selector, 11155111, 1
            )
        );
    }

    function test_rejects_wrong_oracle_verifying_contract() public {
        address wrongVerifyingContract = makeAddr("wrongVerifyingContract");
        _expectMockOracleTargetRevert(
            ORACLE_DOMAIN_NAME,
            "1.2",
            "1.2",
            block.chainid,
            wrongVerifyingContract,
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleVerifyingContract.selector,
                wrongVerifyingContract,
                address(0)
            )
        );
    }

    function test_rejects_wrong_oracle_eip712_domain_version() public {
        _expectMockOracleTargetRevert(
            ORACLE_DOMAIN_NAME,
            "9.9",
            "1.2",
            block.chainid,
            address(0),
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleDomainVersion.selector, "9.9", "1.2"
            )
        );
    }

    function test_rejects_wrong_oracle_domain_version_constant() public {
        _expectMockOracleTargetRevert(
            ORACLE_DOMAIN_NAME,
            "1.2",
            "9.9",
            block.chainid,
            address(0),
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleDomainVersion.selector, "9.9", "1.2"
            )
        );
    }

    function test_rejects_wrong_oracle_implementation_domain_version_constant() public {
        (MockOracleOwner wrongOracleImplOnly,) =
            _deployMockOracle(address(this), ORACLE_DOMAIN_NAME, "1.2", "1.2", block.chainid, address(0));
        MockOracleOwner badImpl =
            new MockOracleOwner(address(this), ORACLE_DOMAIN_NAME, "1.2", "9.9", block.chainid, address(0));
        vm.store(address(wrongOracleImplOnly), ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(badImpl)))));
        address wrongOraclePool = _createPool(address(wrongOracleImplOnly));
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleDomainVersion.selector, "9.9", "1.2"
            )
        );
        _validateTargetsForPool(
            wrongOraclePool,
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(wrongOracleImplOnly),
            address(badImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_unregistered_beacon() public {
        PoolFactory unregisteredFactoryImpl = new PoolFactory();
        PoolFactory unregisteredFactory = PoolFactory(
            address(new ERC1967Proxy(address(unregisteredFactoryImpl), abi.encodeCall(PoolFactory.initialize, ())))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.BeaconNotRegistered.selector,
                address(unregisteredFactory),
                address(beacon)
            )
        );
        script.validateTargets(
            address(unregisteredFactory),
            address(unregisteredFactoryImpl),
            address(beacon),
            poolImpl,
            pool,
            address(oracle),
            address(oracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function test_rejects_wrong_factory_owner() public {
        _expectWrongOwner("factory");
    }

    function test_rejects_wrong_beacon_owner() public {
        _expectWrongOwner("beacon");
    }

    function test_rejects_wrong_oracle_owner() public {
        address unexpectedOwner = makeAddr("unexpectedOwner");
        MockOracleOwner wrongOracle =
            new MockOracleOwner(unexpectedOwner, ORACLE_DOMAIN_NAME, "1.2", "1.2", block.chainid, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOwner.selector,
                "oracle",
                unexpectedOwner,
                address(this),
                SAFE
            )
        );
        script.validateOracleOwner(ISimpleSignedPriceOracleOwner(address(wrongOracle)), address(this), SAFE);
    }

    function test_rejects_wrong_oracle_pending_owner() public {
        address unexpectedPendingOwner = makeAddr("unexpectedPendingOwner");
        oracle.transferOwnership(unexpectedPendingOwner);
        _expectUnexpectedOraclePendingOwner(unexpectedPendingOwner);
    }

    function test_rejects_safe_owned_oracle_with_pending_owner() public {
        address unexpectedPendingOwner = makeAddr("unexpectedPendingOwner");
        oracle.transferOwnership(SAFE);
        vm.prank(SAFE);
        oracle.acceptOwnership();
        vm.prank(SAFE);
        oracle.transferOwnership(unexpectedPendingOwner);
        _expectUnexpectedOraclePendingOwner(unexpectedPendingOwner);
    }

    function _expectUnexpectedOraclePendingOwner(address unexpectedPendingOwner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedPendingOwner.selector, unexpectedPendingOwner, SAFE
            )
        );
        script.validateOracleOwner(ISimpleSignedPriceOracleOwner(address(oracle)), address(this), SAFE);
    }

    function _deployActualTopology(address owner) internal {
        factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeCall(PoolFactory.initialize, ());
        factory = PoolFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        poolImpl = _deployPoolImplementation();
        beacon = new UpgradeableBeacon(poolImpl);
        factory.addPoolImplementation(address(beacon));
        oracleImpl = new SimpleSignedPriceOracle(ORACLE_DOMAIN_NAME);
        bytes memory oracleInit = abi.encodeCall(SimpleSignedPriceOracle.initialize, (owner));
        oracle = SimpleSignedPriceOracle(address(new ERC1967Proxy(address(oracleImpl), oracleInit)));
        pool = _createPool(address(oracle));
        if (owner != address(this)) {
            factory.transferOwnership(owner);
            beacon.transferOwnership(owner);
        }
    }

    function _deployPoolImplementation() internal returns (address) {
        ERC20DepositTokenImplementation depositTokenImpl = new ERC20DepositTokenImplementation();
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator liquidator = new EnglishAuctionCollateralLiquidator(wrappers);
        return address(
            new WeightedRateERC1155CollectionPool(
                address(liquidator),
                makeAddr("delegateRegistryV1"),
                makeAddr("delegateRegistryV2"),
                address(depositTokenImpl),
                wrappers,
                7 days
            )
        );
    }

    function _createPool(address priceOracle) internal returns (address) {
        return factory.createProxied(address(beacon), _poolParams(priceOracle));
    }

    function _createPoolFromBeacon(address poolBeacon, address priceOracle) internal returns (address) {
        return
            address(new BeaconProxy(poolBeacon, abi.encodeWithSignature("initialize(bytes)", _poolParams(priceOracle))));
    }

    function _poolParams(address priceOracle) internal returns (bytes memory) {
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = makeAddr("collateralToken");
        uint64[] memory durations = new uint64[](2);
        durations[0] = 60 days;
        durations[1] = 30 days;
        uint64[] memory rates = new uint64[](2);
        rates[0] = 1;
        rates[1] = 2;
        return abi.encode(collateralTokens, address(new MockERC20Metadata()), priceOracle, durations, rates);
    }

    function _deployMockOracle(
        address owner,
        string memory name,
        string memory eip712Version,
        string memory domainVersion,
        uint256 domainChainId,
        address verifyingContract
    ) internal returns (MockOracleOwner wrongOracle, MockOracleOwner wrongOracleImpl) {
        wrongOracle = new MockOracleOwner(owner, name, eip712Version, domainVersion, domainChainId, verifyingContract);
        wrongOracleImpl =
            new MockOracleOwner(owner, name, eip712Version, domainVersion, domainChainId, verifyingContract);
        vm.store(address(wrongOracle), ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(wrongOracleImpl)))));
    }

    function _expectMockOracleTargetRevert(
        string memory name,
        string memory eip712Version,
        string memory domainVersion,
        uint256 domainChainId,
        address verifyingContract,
        bytes memory expectedRevert
    ) internal {
        (MockOracleOwner wrongOracle, MockOracleOwner wrongOracleImpl) = _deployMockOracle(
            address(this), name, eip712Version, domainVersion, domainChainId, verifyingContract
        );
        address wrongOraclePool = _createPool(address(wrongOracle));
        if (verifyingContract != address(0)) {
            expectedRevert = abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOracleVerifyingContract.selector,
                verifyingContract,
                address(wrongOracle)
            );
        }
        vm.expectRevert(expectedRevert);
        _validateTargetsForPool(
            wrongOraclePool,
            address(factoryImpl),
            address(beacon),
            poolImpl,
            address(wrongOracle),
            address(wrongOracleImpl),
            ORACLE_DOMAIN_NAME
        );
    }

    function _expectWrongOwner(string memory target) internal {
        address unexpectedOwner = makeAddr("unexpectedOwner");
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaLendingPoolFinalizeOwnershipScript.UnexpectedOwner.selector,
                target,
                unexpectedOwner,
                address(this),
                SAFE
            )
        );
        script.validateOwner(target, unexpectedOwner, address(this), SAFE);
    }

    function _validateTargets(
        address expectedFactoryImpl,
        address expectedBeacon,
        address expectedPoolImpl,
        address expectedOracle,
        address expectedOracleImpl,
        string memory expectedOracleDomainName
    ) internal view {
        _validateTargetsForPool(
            pool,
            expectedFactoryImpl,
            expectedBeacon,
            expectedPoolImpl,
            expectedOracle,
            expectedOracleImpl,
            expectedOracleDomainName
        );
    }

    function _validateTargetsForPool(
        address expectedPool,
        address expectedFactoryImpl,
        address expectedBeacon,
        address expectedPoolImpl,
        address expectedOracle,
        address expectedOracleImpl,
        string memory expectedOracleDomainName
    ) internal view {
        script.validateTargets(
            address(factory),
            expectedFactoryImpl,
            expectedBeacon,
            expectedPoolImpl,
            expectedPool,
            expectedOracle,
            expectedOracleImpl,
            expectedOracleDomainName
        );
    }

    function _setEnv(address expectedCurrentOwner, address finalOwner) internal {
        vm.setEnv("FABRICA_LENDING_FACTORY", vm.toString(address(factory)));
        vm.setEnv("FABRICA_LENDING_FACTORY_IMPL", vm.toString(address(factoryImpl)));
        vm.setEnv("FABRICA_LENDING_BEACON", vm.toString(address(beacon)));
        vm.setEnv("FABRICA_LENDING_POOL_IMPL", vm.toString(poolImpl));
        vm.setEnv("FABRICA_LENDING_POOL", vm.toString(pool));
        vm.setEnv("FABRICA_LENDING_ORACLE", vm.toString(address(oracle)));
        vm.setEnv("FABRICA_LENDING_ORACLE_IMPL", vm.toString(address(oracleImpl)));
        vm.setEnv("FABRICA_LENDING_ORACLE_DOMAIN_NAME", ORACLE_DOMAIN_NAME);
        vm.setEnv("FABRICA_LENDING_EXPECTED_CURRENT_OWNER", vm.toString(expectedCurrentOwner));
        vm.setEnv("FABRICA_LENDING_FINAL_OWNER", vm.toString(finalOwner));
    }
}
