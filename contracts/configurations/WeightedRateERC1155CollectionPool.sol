// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import "../BorrowLogic.sol";
import "../LoanReceipt.sol";
import "../Pool.sol";
import "../interfaces/IPool.sol";
import "../rates/WeightedInterestRateModel.sol";
import "../filters/CollectionCollateralFilter.sol";
import "../tokenization/ERC20DepositToken.sol";
import "../oracle/ExternalPriceOracle.sol";

/**
 * @title Pool Configuration with a Weighted Interest Rate Model, Collection
 * Collateral Filter, and native ERC1155 support
 * @dev Only supports ERC1155 transfers for quantity of 1
 * @author MetaStreet Labs
 */
contract WeightedRateERC1155CollectionPool is
    Pool,
    WeightedInterestRateModel,
    CollectionCollateralFilter,
    ERC20DepositToken,
    ExternalPriceOracle
{
    /**************************************************************************/
    /* Immutable State */
    /**************************************************************************/

    /**
     * @notice ERC1155 Collateral Wrapper address
     */
    address private immutable _erc1155CollateralWrapper;

    /**************************************************************************/
    /* Constructor */
    /**************************************************************************/

    /**
     * @notice Pool constructor
     * @param collateralLiquidator Collateral liquidator
     * @param delegateRegistryV1 Delegation registry v1 contract
     * @param delegateRegistryV2 Delegation registry v2 contract
     * @param erc20DepositTokenImplementation ERC20 Deposit Token implementation address
     * @param collateralWrappers Collateral wrappers (must be one, ERC1155 Collateral Wrapper)
     * @param liquidationGracePeriod_ Fabrica ENG-3113: grace period in seconds
     * between default and when liquidate() may be called
     */
    constructor(
        address collateralLiquidator,
        address delegateRegistryV1,
        address delegateRegistryV2,
        address erc20DepositTokenImplementation,
        address[] memory collateralWrappers,
        uint64 liquidationGracePeriod_
    )
        Pool(collateralLiquidator, delegateRegistryV1, delegateRegistryV2, collateralWrappers, liquidationGracePeriod_)
        WeightedInterestRateModel()
        ERC20DepositToken(erc20DepositTokenImplementation)
        ExternalPriceOracle()
    {
        /* Validate collateral wrappers */
        if (collateralWrappers.length != 1) revert InvalidParameters();
        if (
            keccak256(abi.encodePacked(ICollateralWrapper(collateralWrappers[0]).name())) !=
            keccak256("MetaStreet ERC1155 Collateral Wrapper")
        ) revert InvalidParameters();

        /* Disable initialization of implementation contract */
        _storage.currencyToken = IERC20(address(1));

        /* Set ERC1155 collateral wrapper for liquidation */
        _erc1155CollateralWrapper = collateralWrappers[0];
    }

    /**************************************************************************/
    /* Initializer */
    /**************************************************************************/

    /**
     * @notice Initializer
     * @dev Fee-on-transfer currency tokens are not supported
     * @param params ABI-encoded parameters
     */
    function initialize(bytes memory params) external {
        require(address(_storage.currencyToken) == address(0), "Already initialized");

        /* Decode parameters */
        (
            address[] memory collateralTokens_,
            address currencyToken_,
            address priceOracle_,
            uint64[] memory durations_,
            uint64[] memory rates_
        ) = abi.decode(params, (address[], address, address, uint64[], uint64[]));

        /* Initialize Collateral Filter */
        CollectionCollateralFilter._initialize(collateralTokens_);

        /* Initialize External Price Oracle */
        ExternalPriceOracle.__initialize(priceOracle_);

        /* Initialize Pool */
        Pool._initialize(currencyToken_, durations_, rates_);
    }

    /**************************************************************************/
    /* Overrides */
    /**************************************************************************/

    /**
     * @inheritdoc Pool
     */
    function _transferCollateral(
        address from,
        address to,
        address collateralToken,
        uint256 collateralTokenId
    ) internal override {
        /* Use ERC721 transfer for ERC1155 collateral wrapper */
        if (collateralToken == _erc1155CollateralWrapper) {
            super._transferCollateral(from, to, collateralToken, collateralTokenId);
        } else {
            IERC1155(collateralToken).safeTransferFrom(from, to, collateralTokenId, 1, "");
        }
    }

    function _liquidateWithReserve(bytes calldata encodedLoanReceipt, bytes calldata liquidationOracleContext) private {
        /* Handle liquidate accounting and source reserve price */
        (LoanReceipt.LoanReceiptV2 memory loanReceipt, bytes32 loanReceiptHash, uint256 unitReservePrice) = BorrowLogic
            ._liquidateWithReserve(
            _storage,
            encodedLoanReceipt,
            _liquidationGracePeriod,
            collateralToken(),
            _erc1155CollateralWrapper,
            liquidationOracleContext
        );

        /* Revoke delegates */
        BorrowLogic._revokeDelegates(
            _getDelegateStorage(),
            loanReceipt.collateralToken,
            loanReceipt.collateralTokenId,
            _delegateRegistryV1,
            _delegateRegistryV2
        );

        /* Liquidate collateral */
        BorrowLogic._liquidateERC1155CollateralWithReserve(
            _storage,
            address(_collateralLiquidator),
            _erc1155CollateralWrapper,
            loanReceipt.collateralToken,
            loanReceipt.collateralTokenId,
            loanReceipt.collateralWrapperContext,
            encodedLoanReceipt,
            unitReservePrice
        );

        /* Emit Loan Liquidated */
        emit LoanLiquidated(loanReceiptHash);
    }

    /**
     * @notice Fail closed on the legacy liquidation selector because this pool
     * requires oracle context to source an auction reserve.
     */
    function liquidate(bytes calldata) external pure override {
        revert IPool.InvalidLiquidationReserve();
    }

    /**
     * @notice Liquidate an expired loan with oracle context used to source the auction reserve
     *
     * Emits a {LoanLiquidated} event.
     *
     * @param encodedLoanReceipt Encoded loan receipt
     * @param liquidationOracleContext Oracle context for the reserve price quote
     */
    function liquidate(bytes calldata encodedLoanReceipt, bytes calldata liquidationOracleContext)
        external
        nonReentrant
    {
        _liquidateWithReserve(encodedLoanReceipt, liquidationOracleContext);
    }

    /**************************************************************************/
    /* Name */
    /**************************************************************************/

    /**
     * @inheritdoc Pool
     */
    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "WeightedRateERC1155CollectionPool";
    }

    /**************************************************************************/
    /* ERC1155Holder */
    /**************************************************************************/

    /**
     * @notice Accept a single ERC1155 collateral transfer
     * @return ERC1155 receiver selector
     */
    function onERC1155Received(address, address, uint256, uint256, bytes memory) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /**
     * @notice Reject ERC1155 batch transfers
     * @return Zero selector to reject the batch transfer
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4) {
        /* Batch transfers not supported */
        return 0;
    }

    /******************************************************/
    /* ERC165 interface */
    /******************************************************/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) public view override(Pool) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
}
