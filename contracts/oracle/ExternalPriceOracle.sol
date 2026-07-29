// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./PriceOracle.sol";

import "../interfaces/IPriceOracle.sol";

/**
 * @title External Price Oracle
 * @author MetaStreet Labs
 * @dev Fabrica ENG-3519 WP-B: admin setPriceOracle (size-constrained fallback on
 *      WeightedRateERC1155CollectionPool).
 *      SECURITY POSTURE — repoint delay is NOT enforced by this contract.
 *      `_setPriceOracle` applies immediately. Design-review knob: repoint delay =
 *      Safe delay module [operational] vs on-chain scheduler [rejected: EIP-170];
 *      Tim/Fede sign-off pre-deploy. See LENDING-POOL-RUNBOOK.md knobs table.
 */
contract ExternalPriceOracle is PriceOracle {
    /**************************************************************************/
    /* Structures */
    /**************************************************************************/

    /**
     * @custom:storage-location erc7201:externalPriceOracle.priceOracleStorage
     * @param addr Price oracle address
     */
    struct PriceOracleStorage {
        address addr;
    }

    /**************************************************************************/
    /* State */
    /**************************************************************************/

    /**
     * @notice Price oracle storage slot
     * @dev keccak256(abi.encode(uint256(keccak256("externalPriceOracle.priceOracleStorage")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant PRICE_ORACLE_LOCATION = 0x5cc3a0ef4fb602d81e01a142e768b704108e3b2e96852939d75763e011a39b00;

    /**************************************************************************/
    /* Errors */
    /**************************************************************************/

    error InvalidPriceOracle(address priceOracle);
    error PriceOracleUnchanged(address priceOracle);

    /**************************************************************************/
    /* Events */
    /**************************************************************************/

    /**
     * @notice Emitted when the external price oracle address is updated
     * @param previousOracle Previous price oracle address
     * @param newOracle New price oracle address
     * @param caller Caller that applied the change
     */
    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle, address indexed caller);

    /**************************************************************************/
    /* Initializer */
    /**************************************************************************/

    function __initialize(address addr) internal {
        _getPriceOracleStorage().addr = addr;
    }

    /**************************************************************************/
    /* Internal Helpers */
    /**************************************************************************/

    function _getPriceOracleStorage() private pure returns (PriceOracleStorage storage $) {
        assembly {
            $.slot := PRICE_ORACLE_LOCATION
        }
    }

    /**
     * @notice Set the external price oracle address
     * @param newOracle New price oracle address (must have code)
     */
    function _setPriceOracle(address newOracle) internal {
        if (newOracle == address(0) || newOracle.code.length == 0) revert InvalidPriceOracle(newOracle);
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        address previousOracle = $.addr;
        if (newOracle == previousOracle) revert PriceOracleUnchanged(newOracle);
        $.addr = newOracle;
        emit PriceOracleUpdated(previousOracle, newOracle, msg.sender);
    }

    /**************************************************************************/
    /* API */
    /**************************************************************************/

    /**
     * @notice Get live price oracle address
     * @return Price oracle address
     */
    function priceOracle() public view returns (address) {
        return _getPriceOracleStorage().addr;
    }

    /**
     * @inheritdoc PriceOracle
     */
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) public view override returns (uint256) {
        address priceOracle_ = priceOracle();
        return priceOracle_ != address(0)
            ? IPriceOracle(priceOracle_).price(
                collateralToken, currencyToken, tokenIds, tokenIdQuantities, oracleContext
            )
            : 0;
    }
}
