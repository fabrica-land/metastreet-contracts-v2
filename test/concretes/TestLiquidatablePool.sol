// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "fabrica-lending-pools/BorrowLogic.sol";
import "fabrica-lending-pools/LoanReceipt.sol";
import "fabrica-lending-pools/interfaces/IReservePriceCollateralLiquidator.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./TestPermissivePoolBase.sol";

/**
 * @title Concrete permissive pool for the borrow → default → liquidate path,
 * for the Fabrica ENG-3113 liquidation grace-period guard.
 *
 * Adds a real collateral liquidator and a configurable grace period to the
 * shared TestPermissivePoolBase stubs so tests can drive Pool.liquidate()
 * end-to-end against a constructor-set grace window.
 */
contract TestLiquidatablePool is TestPermissivePoolBase {
    constructor(address erc20DepositTokenImpl, address collateralLiquidator, uint64 liquidationGracePeriod_)
        Pool(collateralLiquidator, address(0), address(0), new address[](0), liquidationGracePeriod_)
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestLiquidatablePool";
    }

    function _liquidateForTest(bytes calldata encodedLoanReceipt, bytes calldata liquidationOracleContext) private {
        (LoanReceipt.LoanReceiptV2 memory loanReceipt, bytes32 loanReceiptHash, uint256 unitReservePrice) = BorrowLogic._liquidateWithReserve(
            _storage,
            encodedLoanReceipt,
            _liquidationGracePeriod,
            collateralToken(),
            address(0),
            liquidationOracleContext
        );

        BorrowLogic._revokeDelegates(
            _getDelegateStorage(),
            loanReceipt.collateralToken,
            loanReceipt.collateralTokenId,
            _delegateRegistryV1,
            _delegateRegistryV2
        );

        IERC721(loanReceipt.collateralToken).approve(address(_collateralLiquidator), loanReceipt.collateralTokenId);
        IReservePriceCollateralLiquidator(address(_collateralLiquidator))
            .liquidateWithReserve(
                address(_storage.currencyToken),
                loanReceipt.collateralToken,
                loanReceipt.collateralTokenId,
                loanReceipt.collateralWrapperContext,
                encodedLoanReceipt,
                unitReservePrice
            );

        emit LoanLiquidated(loanReceiptHash);
    }

    function liquidate(bytes calldata encodedLoanReceipt) public override nonReentrant {
        _liquidateForTest(encodedLoanReceipt, encodedLoanReceipt[:0]);
    }

    function liquidate(bytes calldata encodedLoanReceipt, bytes calldata liquidationOracleContext)
        public
        override
        nonReentrant
    {
        _liquidateForTest(encodedLoanReceipt, liquidationOracleContext);
    }
}
