// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ICollateralLiquidator.sol";

/**
 * @title Interface to a reserve-price collateral liquidator
 */
interface IReservePriceCollateralLiquidator is ICollateralLiquidator {
    /**
     * @notice Liquidate collateral with an absolute reserve price in currency tokens
     * @param currencyToken Currency token
     * @param collateralToken Collateral token, either underlying token or collateral wrapper
     * @param collateralTokenId Collateral token ID
     * @param collateralWrapperContext Collateral wrapper context
     * @param liquidationContext Liquidation callback context
     * @param unitReservePrice Reserve price for one underlying collateral unit
     */
    function liquidateWithReserve(
        address currencyToken,
        address collateralToken,
        uint256 collateralTokenId,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext,
        uint256 unitReservePrice
    ) external;
}
