// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

interface IOwnable {
    /// @notice Return the current owner.
    /// @return Current owner address.
    function owner() external view returns (address);

    /// @notice Transfer ownership to a new owner.
    /// @param newOwner New owner address.
    function transferOwnership(address newOwner) external;
}

interface IOwnable2Step is IOwnable {
    /// @notice Return the pending owner for a two-step ownership transfer.
    /// @return Pending owner address.
    function pendingOwner() external view returns (address);

    /// @notice Accept a pending two-step ownership transfer.
    function acceptOwnership() external;
}

interface IPoolFactoryOwner is IOwnable {
    /// @notice Return the ERC1967 implementation backing the PoolFactory proxy.
    /// @return PoolFactory implementation address.
    function getImplementation() external view returns (address);

    /// @notice Return whether an address was created by this factory.
    /// @param pool Pool address to check.
    /// @return True when the address is registered as a pool.
    function isPool(address pool) external view returns (bool);

    /// @notice Return every allowlisted pool implementation or beacon.
    /// @return Allowlisted pool implementation or beacon addresses.
    function getPoolImplementations() external view returns (address[] memory);
}

interface IUpgradeableBeaconOwner is IOwnable {
    /// @notice Return the pool implementation currently served by the beacon.
    /// @return Pool implementation address.
    function implementation() external view returns (address);
}

interface ISimpleSignedPriceOracleOwner is IOwnable2Step {
    /// @notice Return the signing domain version.
    /// @return Signing domain version.
    function DOMAIN_VERSION() external pure returns (string memory);

    /// @notice Return the EIP-712 domain values.
    /// @return fields Bitmap of populated EIP-712 domain fields.
    /// @return name Domain name.
    /// @return version Domain version.
    /// @return chainId Domain chain ID.
    /// @return verifyingContract Domain verifying contract.
    /// @return salt Domain salt.
    /// @return extensions Domain extension list.
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
}

interface IPoolOracleBinding {
    /// @notice Return the oracle configured on the pool.
    /// @return Price oracle address.
    function priceOracle() external view returns (address);
}

/**
 * @title Fabrica Lending Pool ownership handoff
 *
 * Moves the deployer-owned administrative roles created by
 * FabricaLendingPoolStackDeploy.s.sol toward the canonical Fabrica Safe.
 *
 * Required env:
 *   FABRICA_LENDING_FACTORY                 PoolFactory proxy address
 *   FABRICA_LENDING_FACTORY_IMPL            PoolFactory implementation address
 *   FABRICA_LENDING_BEACON                  UpgradeableBeacon address
 *   FABRICA_LENDING_POOL_IMPL               WeightedRateERC1155CollectionPool implementation address
 *   FABRICA_LENDING_POOL                    BeaconProxy pool address using this oracle
 *   FABRICA_LENDING_ORACLE                  SimpleSignedPriceOracle proxy address
 *   FABRICA_LENDING_ORACLE_IMPL             SimpleSignedPriceOracle implementation address
 *   FABRICA_LENDING_ORACLE_DOMAIN_NAME      SimpleSignedPriceOracle EIP-712 domain name
 *   FABRICA_LENDING_EXPECTED_CURRENT_OWNER  broadcaster/deployer that currently owns all three roles
 *   FABRICA_LENDING_FINAL_OWNER             canonical Fabrica Safe
 *
 * Broadcasted calls from the current owner:
 *   1. PoolFactory.transferOwnership(FABRICA_LENDING_FINAL_OWNER)
 *   2. UpgradeableBeacon.transferOwnership(FABRICA_LENDING_FINAL_OWNER)
 *   3. SimpleSignedPriceOracle.transferOwnership(FABRICA_LENDING_FINAL_OWNER)
 *
 * SimpleSignedPriceOracle uses Ownable2Step, so this script only starts that
 * handoff. The Safe must subsequently execute `acceptOwnership()` on the
 * oracle proxy. This script deliberately does not attempt to impersonate or
 * replace that Safe acceptance.
 */
contract FabricaLendingPoolFinalizeOwnershipScript is Script {
    address internal constant CANONICAL_FABRICA_SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    string internal constant ORACLE_DOMAIN_VERSION = "1.2";

    error ExpectedMainnet(uint256 chainId);
    error ZeroAddress(string name);
    error NotContract(string name, address target);
    error NonCanonicalFinalOwner(address finalOwner);
    error ExpectedOwnerMustBroadcast(address expectedCurrentOwner, address broadcaster);
    error FinalOwnerMustDifferFromCurrentOwner(address owner);
    error UnexpectedFactoryImplementation(address actual, address expected);
    error UnexpectedBeaconImplementation(address actual, address expected);
    error UnexpectedOracleImplementation(address actual, address expected);
    error BeaconNotRegistered(address factory, address beacon);
    error UnexpectedOracleDomainName(string actual, string expected);
    error UnexpectedOracleDomainVersion(string actual, string expected);
    error UnexpectedOracleDomainChainId(uint256 actual, uint256 expected);
    error UnexpectedOracleVerifyingContract(address actual, address expected);
    error UnexpectedPoolBeacon(address actual, address expected);
    error PoolNotRegistered(address factory, address pool);
    error UnexpectedPoolOracle(address actual, address expected);
    error UnexpectedOwner(string target, address actual, address expectedCurrentOwner, address finalOwner);
    error UnexpectedPendingOwner(address actual, address finalOwner);

    /// @notice Foundry setup hook.
    function setUp() public {}

    /// @notice Start or resume deployer-side ownership handoff to the canonical Fabrica Safe.
    function run() public {
        if (block.chainid != 1) revert ExpectedMainnet(block.chainid);
        address factory = vm.envAddress("FABRICA_LENDING_FACTORY");
        address factoryImpl = vm.envAddress("FABRICA_LENDING_FACTORY_IMPL");
        address beacon = vm.envAddress("FABRICA_LENDING_BEACON");
        address poolImpl = vm.envAddress("FABRICA_LENDING_POOL_IMPL");
        address pool = vm.envAddress("FABRICA_LENDING_POOL");
        address oracle = vm.envAddress("FABRICA_LENDING_ORACLE");
        address oracleImpl = vm.envAddress("FABRICA_LENDING_ORACLE_IMPL");
        string memory oracleDomainName = vm.envString("FABRICA_LENDING_ORACLE_DOMAIN_NAME");
        address expectedCurrentOwner = vm.envAddress("FABRICA_LENDING_EXPECTED_CURRENT_OWNER");
        address finalOwner = vm.envAddress("FABRICA_LENDING_FINAL_OWNER");
        _requireNonZero("factory", factory);
        _requireNonZero("factoryImpl", factoryImpl);
        _requireNonZero("beacon", beacon);
        _requireNonZero("poolImpl", poolImpl);
        _requireNonZero("pool", pool);
        _requireNonZero("oracle", oracle);
        _requireNonZero("oracleImpl", oracleImpl);
        _requireNonZero("expectedCurrentOwner", expectedCurrentOwner);
        _requireNonZero("finalOwner", finalOwner);
        _validateOwnerConfig(expectedCurrentOwner, finalOwner, msg.sender);
        _validateTargets(factory, factoryImpl, beacon, poolImpl, pool, oracle, oracleImpl, oracleDomainName);
        console.log("Factory proxy:", factory);
        console.log("Beacon:", beacon);
        console.log("Pool:", pool);
        console.log("Oracle proxy:", oracle);
        console.log("Current owner:", expectedCurrentOwner);
        console.log("Final Safe owner:", finalOwner);
        console.log("Safe oracle acceptOwnership calldata:");
        console.logBytes(abi.encodeCall(IOwnable2Step.acceptOwnership, ()));
        vm.startBroadcast(expectedCurrentOwner);
        _handoff(
            IPoolFactoryOwner(factory),
            IUpgradeableBeaconOwner(beacon),
            ISimpleSignedPriceOracleOwner(oracle),
            expectedCurrentOwner,
            finalOwner
        );
        vm.stopBroadcast();
        console.log("=== Fabrica Lending Pool Safe ownership handoff ready for Safe accept ===");
        console.log("Factory owner:", IPoolFactoryOwner(factory).owner());
        console.log("Beacon owner:", IUpgradeableBeaconOwner(beacon).owner());
        console.log("Oracle owner:", ISimpleSignedPriceOracleOwner(oracle).owner());
        console.log("Oracle pending owner:", ISimpleSignedPriceOracleOwner(oracle).pendingOwner());
    }

    function _requireNonZero(string memory name, address value) internal pure {
        if (value == address(0)) revert ZeroAddress(name);
    }

    function _requireContract(string memory name, address target) internal view {
        if (target.code.length == 0) revert NotContract(name, target);
    }

    function _validateOwnerConfig(address expectedCurrentOwner, address finalOwner, address broadcaster) internal view {
        if (finalOwner != CANONICAL_FABRICA_SAFE) revert NonCanonicalFinalOwner(finalOwner);
        _requireContract("finalOwner", finalOwner);
        if (expectedCurrentOwner == finalOwner) revert FinalOwnerMustDifferFromCurrentOwner(finalOwner);
        if (expectedCurrentOwner != broadcaster) {
            revert ExpectedOwnerMustBroadcast(expectedCurrentOwner, broadcaster);
        }
    }

    function _validateTargets(
        address factory,
        address factoryImpl,
        address beacon,
        address poolImpl,
        address pool,
        address oracle,
        address oracleImpl,
        string memory oracleDomainName
    ) internal view {
        _requireContract("factory", factory);
        _requireContract("factoryImpl", factoryImpl);
        _requireContract("beacon", beacon);
        _requireContract("poolImpl", poolImpl);
        _requireContract("pool", pool);
        _requireContract("oracle", oracle);
        _requireContract("oracleImpl", oracleImpl);
        _validateFactory(factory, factoryImpl, beacon, pool);
        _validateBeacon(beacon, poolImpl);
        _validatePool(pool, beacon, oracle);
        _validateOracle(oracle, oracleImpl, oracleDomainName);
    }

    function _validateFactory(address factory, address factoryImpl, address beacon, address pool) internal view {
        if (IPoolFactoryOwner(factory).getImplementation() != factoryImpl) {
            revert UnexpectedFactoryImplementation(IPoolFactoryOwner(factory).getImplementation(), factoryImpl);
        }
        if (!_contains(IPoolFactoryOwner(factory).getPoolImplementations(), beacon)) {
            revert BeaconNotRegistered(factory, beacon);
        }
        if (!IPoolFactoryOwner(factory).isPool(pool)) revert PoolNotRegistered(factory, pool);
    }

    function _validateBeacon(address beacon, address poolImpl) internal view {
        if (IUpgradeableBeaconOwner(beacon).implementation() != poolImpl) {
            revert UnexpectedBeaconImplementation(IUpgradeableBeaconOwner(beacon).implementation(), poolImpl);
        }
    }

    function _validatePool(address pool, address beacon, address oracle) internal view {
        address poolBeacon = address(uint160(uint256(vm.load(pool, ERC1967_BEACON_SLOT))));
        if (poolBeacon != beacon) revert UnexpectedPoolBeacon(poolBeacon, beacon);
        address poolOracle = IPoolOracleBinding(pool).priceOracle();
        if (poolOracle != oracle) revert UnexpectedPoolOracle(poolOracle, oracle);
    }

    function _validateOracle(address oracle, address oracleImpl, string memory oracleDomainName) internal view {
        address actualOracleImpl = address(uint160(uint256(vm.load(oracle, ERC1967_IMPLEMENTATION_SLOT))));
        if (actualOracleImpl != oracleImpl) revert UnexpectedOracleImplementation(actualOracleImpl, oracleImpl);
        (
            string memory domainName,
            string memory eip712DomainVersion,
            uint256 domainChainId,
            address verifyingContract
        ) = _oracleDomain(ISimpleSignedPriceOracleOwner(oracle));
        if (keccak256(bytes(domainName)) != keccak256(bytes(oracleDomainName))) {
            revert UnexpectedOracleDomainName(domainName, oracleDomainName);
        }
        if (domainChainId != block.chainid) revert UnexpectedOracleDomainChainId(domainChainId, block.chainid);
        if (verifyingContract != oracle) revert UnexpectedOracleVerifyingContract(verifyingContract, oracle);
        if (keccak256(bytes(eip712DomainVersion)) != keccak256(bytes(ORACLE_DOMAIN_VERSION))) {
            revert UnexpectedOracleDomainVersion(eip712DomainVersion, ORACLE_DOMAIN_VERSION);
        }
        string memory domainVersion = ISimpleSignedPriceOracleOwner(oracle).DOMAIN_VERSION();
        if (keccak256(bytes(domainVersion)) != keccak256(bytes(ORACLE_DOMAIN_VERSION))) {
            revert UnexpectedOracleDomainVersion(domainVersion, ORACLE_DOMAIN_VERSION);
        }
        string memory implDomainVersion = ISimpleSignedPriceOracleOwner(oracleImpl).DOMAIN_VERSION();
        if (keccak256(bytes(implDomainVersion)) != keccak256(bytes(ORACLE_DOMAIN_VERSION))) {
            revert UnexpectedOracleDomainVersion(implDomainVersion, ORACLE_DOMAIN_VERSION);
        }
    }

    function _oracleDomain(ISimpleSignedPriceOracleOwner oracle)
        internal
        view
        returns (string memory name, string memory version, uint256 chainId, address verifyingContract)
    {
        (, name, version, chainId, verifyingContract,,) = oracle.eip712Domain();
    }

    function _validateOwner(string memory target, address actual, address expectedCurrentOwner, address finalOwner)
        internal
        pure
    {
        if (actual != expectedCurrentOwner && actual != finalOwner) {
            revert UnexpectedOwner(target, actual, expectedCurrentOwner, finalOwner);
        }
    }

    function _validateOracleOwner(
        ISimpleSignedPriceOracleOwner oracle,
        address expectedCurrentOwner,
        address finalOwner
    ) internal view {
        address owner = oracle.owner();
        address pendingOwner = oracle.pendingOwner();
        if (owner == expectedCurrentOwner) {
            if (pendingOwner != address(0) && pendingOwner != finalOwner) {
                revert UnexpectedPendingOwner(pendingOwner, finalOwner);
            }
            return;
        }
        if (owner == finalOwner) {
            if (pendingOwner != address(0)) revert UnexpectedPendingOwner(pendingOwner, finalOwner);
            return;
        }
        revert UnexpectedOwner("oracle", owner, expectedCurrentOwner, finalOwner);
    }

    function _transferIfCurrentOwner(IOwnable ownable, address expectedCurrentOwner, address finalOwner) internal {
        if (ownable.owner() == expectedCurrentOwner) ownable.transferOwnership(finalOwner);
    }

    function _startOracleTransferIfNeeded(
        ISimpleSignedPriceOracleOwner oracle,
        address expectedCurrentOwner,
        address finalOwner
    ) internal {
        if (oracle.owner() == expectedCurrentOwner && oracle.pendingOwner() != finalOwner) {
            oracle.transferOwnership(finalOwner);
        }
    }

    function _handoff(
        IPoolFactoryOwner factory,
        IUpgradeableBeaconOwner beacon,
        ISimpleSignedPriceOracleOwner oracle,
        address expectedCurrentOwner,
        address finalOwner
    ) internal {
        _validateOwner("factory", factory.owner(), expectedCurrentOwner, finalOwner);
        _validateOwner("beacon", beacon.owner(), expectedCurrentOwner, finalOwner);
        _validateOracleOwner(oracle, expectedCurrentOwner, finalOwner);
        _transferIfCurrentOwner(factory, expectedCurrentOwner, finalOwner);
        _transferIfCurrentOwner(beacon, expectedCurrentOwner, finalOwner);
        _startOracleTransferIfNeeded(oracle, expectedCurrentOwner, finalOwner);
        _validateOwner("factory", factory.owner(), expectedCurrentOwner, finalOwner);
        _validateOwner("beacon", beacon.owner(), expectedCurrentOwner, finalOwner);
        _validateOracleOwner(oracle, expectedCurrentOwner, finalOwner);
    }

    function _contains(address[] memory values, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) return true;
        }
        return false;
    }
}
