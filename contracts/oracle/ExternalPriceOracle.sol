// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./PriceOracle.sol";

import "../interfaces/IPriceOracle.sol";

/**
 * @title External Price Oracle
 * @author MetaStreet Labs
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

    /**
     * @notice SimpleSignedPriceOracle.InvalidLength() selector
     */
    bytes4 private constant PRICE_ORACLE_INVALID_LENGTH_SELECTOR = 0x947d5a84;

    /**************************************************************************/
    /* Errors */
    /**************************************************************************/

    /**
     * @notice Invalid price oracle
     * @param priceOracle Price oracle address
     */
    error InvalidPriceOracle(address priceOracle);

    /**
     * @notice Price oracle unchanged
     * @param priceOracle Price oracle address
     */
    error PriceOracleUnchanged(address priceOracle);

    /**************************************************************************/
    /* Events */
    /**************************************************************************/

    /**
     * @notice Emitted when the external price oracle is updated
     * @param previousOracle Previous price oracle address
     * @param newOracle New price oracle address
     * @param caller Caller that updated the oracle
     */
    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle, address indexed caller);

    /**************************************************************************/
    /* Initializer */
    /**************************************************************************/

    /**
     * @notice ExternalPriceOracle initializer
     */
    function __initialize(address addr) internal {
        _getPriceOracleStorage().addr = addr;
    }

    /**************************************************************************/
    /* Internal Helpers */
    /**************************************************************************/

    /**
     * @notice Get reference to ERC-7201 price oracle address storage
     *
     * @return $ Reference to price oracle address storage
     */
    function _getPriceOracleStorage() private pure returns (PriceOracleStorage storage $) {
        assembly {
            $.slot := PRICE_ORACLE_LOCATION
        }
    }

    /**
     * @notice Set the external price oracle address
     * @param newOracle New price oracle address
     */
    function _setPriceOracle(address newOracle) internal {
        if (newOracle == address(0) || newOracle.code.length == 0) revert InvalidPriceOracle(newOracle);
        _validatePriceOracleShape(newOracle);
        PriceOracleStorage storage $ = _getPriceOracleStorage();
        address previousOracle = $.addr;
        if (newOracle == previousOracle) revert PriceOracleUnchanged(newOracle);
        $.addr = newOracle;
        emit PriceOracleUpdated(previousOracle, newOracle, msg.sender);
    }

    /**
     * @notice Validate that the candidate oracle exposes the expected price() API shape
     * @param newOracle New price oracle address
     */
    function _validatePriceOracleShape(address newOracle) private view {
        uint256[] memory emptyTokenIds = new uint256[](0);
        (bool ok, bytes memory data) = newOracle.staticcall(
            abi.encodeCall(
                IPriceOracle.price,
                (address(1), address(1), emptyTokenIds, emptyTokenIds, abi.encode(emptyTokenIds))
            )
        );
        if (ok) {
            if (data.length != 32) revert InvalidPriceOracle(newOracle);
        } else if (data.length < 4 || bytes4(data) != PRICE_ORACLE_INVALID_LENGTH_SELECTOR) {
            revert InvalidPriceOracle(newOracle);
        }
    }

    /**************************************************************************/
    /* API */
    /**************************************************************************/

    /**
     * @notice Get price oracle address
     *
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
        /* Cache price oracle address */
        address priceOracle_ = priceOracle();

        /* Return oracle price if price oracle exists, else 0 */
        return
            priceOracle_ != address(0)
                ? IPriceOracle(priceOracle_).price(
                    collateralToken,
                    currencyToken,
                    tokenIds,
                    tokenIdQuantities,
                    oracleContext
                )
                : 0;
    }
}
