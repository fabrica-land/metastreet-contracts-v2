// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "fabrica-lending-pools/Pool.sol";
import "fabrica-lending-pools/interfaces/IPool.sol";
import "fabrica-lending-pools/interfaces/IPriceOracle.sol";
import "fabrica-lending-pools/configurations/WeightedRateCollectionPool.sol";
import "fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";
import "fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import "fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import "fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";

import "../contracts/test/TestPriceOracle.sol";
import "../contracts/test/tokens/TestERC1155.sol";
import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";
import "./concretes/TestLiquidatablePool.sol";

contract StrictERC1155ReserveOracle is IPriceOracle {
    uint256 internal immutable _expectedTokenId;
    uint256 internal immutable _expectedQuantity;
    bytes internal _borrowContext;
    bytes internal _liquidationContext;
    uint256 internal _price;

    constructor(
        uint256 expectedTokenId,
        uint256 expectedQuantity,
        bytes memory borrowContext,
        bytes memory liquidationContext,
        uint256 price_
    ) {
        _expectedTokenId = expectedTokenId;
        _expectedQuantity = expectedQuantity;
        _borrowContext = borrowContext;
        _liquidationContext = liquidationContext;
        _price = price_;
    }

    function price(
        address,
        address,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256) {
        bool expectedCollateral = tokenIds.length == 1 && tokenIds[0] == _expectedTokenId
            && tokenIdQuantities.length == 1 && tokenIdQuantities[0] == _expectedQuantity;
        bool expectedContext = keccak256(oracleContext) == keccak256(_borrowContext)
            || keccak256(oracleContext) == keccak256(_liquidationContext);
        return expectedCollateral && expectedContext ? _price : 0;
    }
}

/**
 * ENG-3655 reserve-price coverage for the English auction liquidator and the
 * Pool liquidation wrapper that sources reserves from the configured oracle.
 */
contract FabricaLendingPoolAuctionReserveTest is Test {
    using stdStorage for StdStorage;

    EnglishAuctionCollateralLiquidator internal liquidator;
    TestLiquidatablePool internal pool;
    TestERC20 internal currency;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal source = makeAddr("liquidation-source");
    address internal bidder = makeAddr("bidder");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint256 internal constant RESERVE = 150 ether;
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant AUCTION_DURATION = 1 days;
    uint64 internal constant TIME_EXTENSION_WINDOW = 15 minutes;
    uint64 internal constant TIME_EXTENSION = 30 minutes;
    uint64 internal constant MINIMUM_BID_BASIS_POINTS = 500;
    bytes internal constant LIQUIDATION_CONTEXT = hex"3655";
    bytes internal constant BORROW_CONTEXT = hex"b0770a";

    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);

    function setUp() public {
        vm.warp(1_700_000_000);

        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = _deployLiquidator();
    }

    function _deployLiquidator() internal returns (EnglishAuctionCollateralLiquidator) {
        return _deployLiquidator(new address[](0));
    }

    function _deployLiquidator(address[] memory wrappers) internal returns (EnglishAuctionCollateralLiquidator) {
        EnglishAuctionCollateralLiquidator implementation = new EnglishAuctionCollateralLiquidator(wrappers);
        bytes memory init = abi.encodeCall(
            EnglishAuctionCollateralLiquidator.initialize,
            (AUCTION_DURATION, TIME_EXTENSION_WINDOW, TIME_EXTENSION, MINIMUM_BID_BASIS_POINTS)
        );

        return EnglishAuctionCollateralLiquidator(address(new ERC1967Proxy(address(implementation), init)));
    }

    function _liquidationHash(address collateralToken, uint256 collateralTokenId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, collateralToken, collateralTokenId, block.timestamp));
    }

    function _startDirectLiquidation(uint256 tokenId, uint256 reservePrice) internal returns (bytes32 liquidationHash) {
        nft.mint(source, tokenId);
        vm.prank(source);
        nft.approve(address(liquidator), tokenId);

        liquidationHash = _liquidationHash(address(nft), tokenId);

        vm.prank(source);
        liquidator.liquidateWithReserve(address(currency), address(nft), tokenId, "", LIQUIDATION_CONTEXT, reservePrice);
    }

    function _fundAndApproveBidder(uint256 amount) internal {
        currency.mint(bidder, amount);
        vm.prank(bidder);
        currency.approve(address(liquidator), type(uint256).max);
    }

    function test_legacy_liquidator_path_starts_no_reserve_auction() public {
        nft.mint(source, 1);
        vm.prank(source);
        nft.approve(address(liquidator), 1);

        bytes32 liquidationHash = _liquidationHash(address(nft), 1);
        vm.prank(source);
        liquidator.liquidate(address(currency), address(nft), 1, "", LIQUIDATION_CONTEXT);

        EnglishAuctionCollateralLiquidator.Auction memory auction =
            liquidator.auctions(liquidationHash, address(nft), 1);
        assertEq(auction.quantity, 1, "auction quantity");
        assertEq(liquidator.auctionReservePrice(liquidationHash, address(nft), 1), 0, "legacy reserve");
    }

    function test_liquidator_rejects_zero_reserve() public {
        vm.expectRevert(EnglishAuctionCollateralLiquidator.ReserveRequired.selector);
        liquidator.liquidateWithReserve(address(currency), address(nft), 1, "", LIQUIDATION_CONTEXT, 0);
    }

    function test_bid_below_reserve_reverts_with_amount_and_reserve() public {
        bytes32 liquidationHash = _startDirectLiquidation(1, RESERVE);
        _fundAndApproveBidder(RESERVE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuctionCollateralLiquidator.BidBelowReserve.selector, RESERVE - 1, RESERVE)
        );
        vm.prank(bidder);
        liquidator.bid(liquidationHash, address(nft), 1, RESERVE - 1);
    }

    function test_bid_at_reserve_settles_and_clears_reserve() public {
        bytes32 liquidationHash = _startDirectLiquidation(2, RESERVE);
        _fundAndApproveBidder(RESERVE);

        vm.prank(bidder);
        liquidator.bid(liquidationHash, address(nft), 2, RESERVE);

        EnglishAuctionCollateralLiquidator.Auction memory auction =
            liquidator.auctions(liquidationHash, address(nft), 2);
        assertEq(auction.highestBidder, bidder, "highest bidder");
        assertEq(auction.highestBid, RESERVE, "highest bid");

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(bidder);
        liquidator.claim(liquidationHash, address(nft), 2, LIQUIDATION_CONTEXT);

        assertEq(nft.ownerOf(2), bidder, "winner owns collateral");
        assertEq(currency.balanceOf(source), RESERVE, "source receives proceeds");
        assertEq(liquidator.auctionReservePrice(liquidationHash, address(nft), 2), 0, "reserve cleared");
    }

    function test_claim_refuses_winning_bid_below_defensive_reserve() public {
        bytes32 liquidationHash = _startDirectLiquidation(3, RESERVE);
        _fundAndApproveBidder(RESERVE);

        vm.prank(bidder);
        liquidator.bid(liquidationHash, address(nft), 3, RESERVE);

        stdstore.target(address(liquidator)).sig(liquidator.auctionReservePrice.selector).with_key(liquidationHash)
            .with_key(address(nft)).with_key(3).checked_write(RESERVE + 1);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.expectRevert(EnglishAuctionCollateralLiquidator.InvalidClaim.selector);
        vm.prank(bidder);
        liquidator.claim(liquidationHash, address(nft), 3, LIQUIDATION_CONTEXT);
    }

    function _initPoolAndBorrow(uint256 tokenId)
        internal
        returns (bytes memory encodedLoanReceipt, bytes32 loanReceiptHash)
    {
        pool = new TestLiquidatablePool(address(erc20DepositTokenImpl), address(liquidator), 0);

        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(address(currency), durations, rates);

        currency.mint(lender, LENDER_DEPOSIT);
        vm.prank(lender);
        currency.approve(address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);

        nft.mint(borrower, tokenId);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(borrower, PRINCIPAL, DURATION, address(nft), tokenId, PRINCIPAL, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 1 && logs[i].topics[0] == topic) {
                return (abi.decode(logs[i].data, (bytes)), logs[i].topics[1]);
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_pool_liquidation_fails_closed_on_zero_oracle_reserve() public {
        (bytes memory receipt, bytes32 loanReceiptHash) = _initPoolAndBorrow(10);
        vm.warp(block.timestamp + DURATION + 1);
        pool.setTestOraclePrice(0);

        vm.expectRevert(IPool.InvalidLiquidationReserve.selector);
        pool.liquidate(receipt, LIQUIDATION_CONTEXT);

        assertEq(uint256(pool.loans(loanReceiptHash)), uint256(Pool.LoanStatus.Active), "loan remains active");
        assertEq(nft.ownerOf(10), address(pool), "collateral remains escrowed");
    }

    function test_pool_liquidation_fails_closed_when_oracle_reverts() public {
        (bytes memory receipt, bytes32 loanReceiptHash) = _initPoolAndBorrow(11);
        vm.warp(block.timestamp + DURATION + 1);
        pool.setTestOracleReverts(true);

        vm.expectRevert(bytes("oracle reverted"));
        pool.liquidate(receipt, LIQUIDATION_CONTEXT);

        assertEq(uint256(pool.loans(loanReceiptHash)), uint256(Pool.LoanStatus.Active), "loan remains active");
        assertEq(nft.ownerOf(11), address(pool), "collateral remains escrowed");
    }

    function test_pool_liquidation_sets_oracle_reserve_on_auction() public {
        (bytes memory receipt, bytes32 loanReceiptHash) = _initPoolAndBorrow(12);
        vm.warp(block.timestamp + DURATION + 1);
        pool.setTestOraclePrice(RESERVE);

        bytes32 liquidationHash = _liquidationHash(address(nft), 12);
        pool.liquidate(receipt, LIQUIDATION_CONTEXT);

        assertEq(uint256(pool.loans(loanReceiptHash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated");
        assertEq(nft.ownerOf(12), address(liquidator), "liquidator escrows collateral");
        assertEq(liquidator.auctionReservePrice(liquidationHash, address(nft), 12), RESERVE, "reserve set");
    }

    function _borrowOption(Pool.BorrowOptions tag, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(uint256(tag)), uint16(data.length), data);
    }

    function test_weighted_erc1155_liquidation_prices_underlying_collateral_for_wrapped_loan() public {
        uint256 underlyingTokenId = 3655;
        TestERC1155 erc1155 = new TestERC1155("");
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        StrictERC1155ReserveOracle oracle =
            new StrictERC1155ReserveOracle(underlyingTokenId, 1, BORROW_CONTEXT, LIQUIDATION_CONTEXT, RESERVE);

        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator reserveLiquidator = _deployLiquidator(wrappers);
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(erc1155);
        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        WeightedRateERC1155CollectionPool implementation = new WeightedRateERC1155CollectionPool(
            address(reserveLiquidator), address(0), address(0), address(erc20DepositTokenImpl), wrappers, 0
        );
        WeightedRateERC1155CollectionPool weightedPool = WeightedRateERC1155CollectionPool(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WeightedRateERC1155CollectionPool.initialize,
                        (abi.encode(collateralTokens, address(currency), address(oracle), durations, rates))
                    )
                )
            )
        );

        currency.mint(lender, LENDER_DEPOSIT);
        vm.prank(lender);
        currency.approve(address(weightedPool), type(uint256).max);
        vm.prank(lender);
        weightedPool.deposit(TICK, LENDER_DEPOSIT, 1);

        erc1155.mint(borrower, underlyingTokenId, 1, "");
        vm.prank(borrower);
        erc1155.setApprovalForAll(address(wrapper), true);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = underlyingTokenId;
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1;
        uint256 nonce = wrapper.nonce();

        vm.prank(borrower);
        uint256 wrappedTokenId = wrapper.mint(address(erc1155), tokenIds, quantities);

        bytes memory wrapperContext = abi.encode(address(erc1155), nonce, uint256(1), tokenIds, quantities);
        bytes memory options = bytes.concat(
            _borrowOption(Pool.BorrowOptions.CollateralWrapperContext, wrapperContext),
            _borrowOption(Pool.BorrowOptions.OracleContext, BORROW_CONTEXT)
        );

        vm.prank(borrower);
        wrapper.approve(address(weightedPool), wrappedTokenId);

        vm.recordLogs();
        vm.prank(borrower);
        weightedPool.borrow(
            borrower, PRINCIPAL, DURATION, address(wrapper), wrappedTokenId, LENDER_DEPOSIT, poolTicks(), options
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 loanTopic = keccak256("LoanOriginated(bytes32,bytes)");
        bytes memory receipt;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(weightedPool) && logs[i].topics.length > 1 && logs[i].topics[0] == loanTopic)
            {
                receipt = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        assertGt(receipt.length, 0, "LoanOriginated event not found");

        vm.warp(block.timestamp + DURATION + 1);
        bytes32 liquidationHash = _liquidationHash(address(wrapper), wrappedTokenId);
        weightedPool.liquidate(receipt, LIQUIDATION_CONTEXT);

        assertEq(
            reserveLiquidator.auctionReservePrice(liquidationHash, address(erc1155), underlyingTokenId),
            RESERVE,
            "reserve sourced from underlying ERC1155 id"
        );
    }

    function test_reserve_aware_liquidation_allows_single_wrapped_id_with_quantity_above_one() public {
        TestERC1155 erc1155 = new TestERC1155("");
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator reserveLiquidator = _deployLiquidator(wrappers);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 77;
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 2;

        erc1155.mint(source, 77, 2, "");
        vm.prank(source);
        erc1155.setApprovalForAll(address(wrapper), true);
        uint256 nonce = wrapper.nonce();
        vm.prank(source);
        uint256 wrappedTokenId = wrapper.mint(address(erc1155), tokenIds, quantities);
        bytes memory wrapperContext = abi.encode(address(erc1155), nonce, uint256(2), tokenIds, quantities);

        vm.prank(source);
        wrapper.approve(address(reserveLiquidator), wrappedTokenId);

        bytes32 liquidationHash = _liquidationHash(address(wrapper), wrappedTokenId);
        vm.prank(source);
        reserveLiquidator.liquidateWithReserve(
            address(currency), address(wrapper), wrappedTokenId, wrapperContext, LIQUIDATION_CONTEXT, RESERVE
        );

        assertEq(
            reserveLiquidator.auctionReservePrice(liquidationHash, address(erc1155), 77),
            RESERVE * 2,
            "quantity reserve"
        );
    }

    function test_reserve_aware_liquidation_rejects_heterogeneous_wrapper_bundle() public {
        TestERC1155 erc1155 = new TestERC1155("");
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator reserveLiquidator = _deployLiquidator(wrappers);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 1;
        quantities[1] = 1;

        erc1155.mint(source, 1, 1, "");
        erc1155.mint(source, 2, 1, "");
        vm.prank(source);
        erc1155.setApprovalForAll(address(wrapper), true);
        uint256 nonce = wrapper.nonce();
        vm.prank(source);
        uint256 wrappedTokenId = wrapper.mint(address(erc1155), tokenIds, quantities);
        bytes memory wrapperContext = abi.encode(address(erc1155), nonce, uint256(2), tokenIds, quantities);

        vm.prank(source);
        wrapper.approve(address(reserveLiquidator), wrappedTokenId);

        vm.expectRevert(EnglishAuctionCollateralLiquidator.ReserveRequired.selector);
        vm.prank(source);
        reserveLiquidator.liquidateWithReserve(
            address(currency), address(wrapper), wrappedTokenId, wrapperContext, LIQUIDATION_CONTEXT, RESERVE
        );
    }

    function test_weighted_collection_pool_legacy_liquidation_still_works_with_english_auction() public {
        TestPriceOracle oracle = new TestPriceOracle();
        address[] memory wrappers = new address[](0);
        WeightedRateCollectionPool implementation = new WeightedRateCollectionPool(
            address(liquidator), address(0), address(0), address(erc20DepositTokenImpl), wrappers, 0
        );

        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(nft);
        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        WeightedRateCollectionPool weightedPool = WeightedRateCollectionPool(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WeightedRateCollectionPool.initialize,
                        (abi.encode(collateralTokens, address(currency), address(oracle), durations, rates))
                    )
                )
            )
        );

        currency.mint(lender, LENDER_DEPOSIT);
        vm.prank(lender);
        currency.approve(address(weightedPool), type(uint256).max);
        vm.prank(lender);
        weightedPool.deposit(TICK, LENDER_DEPOSIT, 1);

        nft.mint(borrower, 99);
        vm.prank(borrower);
        nft.approve(address(weightedPool), 99);

        vm.recordLogs();
        vm.prank(borrower);
        weightedPool.borrow(borrower, PRINCIPAL, DURATION, address(nft), 99, LENDER_DEPOSIT, poolTicks(), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 loanTopic = keccak256("LoanOriginated(bytes32,bytes)");
        bytes memory receipt;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(weightedPool) && logs[i].topics.length > 1 && logs[i].topics[0] == loanTopic)
            {
                receipt = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        assertGt(receipt.length, 0, "LoanOriginated event not found");

        vm.warp(block.timestamp + DURATION + 1);
        bytes32 liquidationHash = _liquidationHash(address(nft), 99);
        weightedPool.liquidate(receipt);

        EnglishAuctionCollateralLiquidator.Auction memory auction =
            liquidator.auctions(liquidationHash, address(nft), 99);
        assertEq(auction.quantity, 1, "legacy pool auction quantity");
        assertEq(liquidator.auctionReservePrice(liquidationHash, address(nft), 99), 0, "legacy pool reserve");
    }

    function poolTicks() internal pure returns (uint128[] memory poolTicks_) {
        poolTicks_ = new uint128[](1);
        poolTicks_[0] = TICK;
    }
}
