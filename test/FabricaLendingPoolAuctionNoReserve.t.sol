// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "fabrica-lending-pools/Pool.sol";
import "fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";
import "fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import "fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import "fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";

import "../contracts/test/TestPriceOracle.sol";
import "../contracts/test/tokens/TestERC1155.sol";
import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";

contract FabricaLendingPoolAuctionNoReserveTest is Test {
    EnglishAuctionCollateralLiquidator internal liquidator;
    TestERC20 internal currency;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal source = makeAddr("liquidation-source");
    address internal firstBidder = makeAddr("first-bidder");
    address internal highestBidder = makeAddr("highest-bidder");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant AUCTION_DURATION = 1 days;
    uint64 internal constant TIME_EXTENSION_WINDOW = 15 minutes;
    uint64 internal constant TIME_EXTENSION = 30 minutes;
    uint64 internal constant MINIMUM_BID_BASIS_POINTS = 500;
    bytes internal constant LIQUIDATION_CONTEXT = hex"3695";

    function setUp() public {
        vm.warp(1_700_000_000);

        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();

        EnglishAuctionCollateralLiquidator implementation = new EnglishAuctionCollateralLiquidator(new address[](0));
        bytes memory init = abi.encodeCall(
            EnglishAuctionCollateralLiquidator.initialize,
            (AUCTION_DURATION, TIME_EXTENSION_WINDOW, TIME_EXTENSION, MINIMUM_BID_BASIS_POINTS)
        );
        liquidator = EnglishAuctionCollateralLiquidator(address(new ERC1967Proxy(address(implementation), init)));
    }

    function test_first_bid_has_no_reserve_floor_and_highest_bid_claims() public {
        bytes32 liquidationHash = _startLiquidation(1);

        _fundAndApprove(firstBidder, 1);
        vm.prank(firstBidder);
        liquidator.bid(liquidationHash, address(nft), 1, 1);

        _fundAndApprove(highestBidder, 2);
        vm.prank(highestBidder);
        liquidator.bid(liquidationHash, address(nft), 1, 2);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(highestBidder);
        liquidator.claim(liquidationHash, address(nft), 1, LIQUIDATION_CONTEXT);

        assertEq(nft.ownerOf(1), highestBidder, "highest bidder owns collateral");
        assertEq(currency.balanceOf(source), 2, "source receives highest bid");
        assertEq(currency.balanceOf(firstBidder), 1, "first bid refunded");
    }

    function test_no_bid_auction_claim_reverts_like_upstream() public {
        bytes32 liquidationHash = _startLiquidation(2);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.expectRevert(EnglishAuctionCollateralLiquidator.InvalidClaim.selector);
        liquidator.claim(liquidationHash, address(nft), 2, LIQUIDATION_CONTEXT);

        EnglishAuctionCollateralLiquidator.Auction memory auction =
            liquidator.auctions(liquidationHash, address(nft), 2);
        assertEq(auction.highestBidder, address(0), "no bidder");
        assertEq(auction.endTime, 0, "auction not started");
        assertEq(nft.ownerOf(2), address(liquidator), "collateral remains escrowed");
    }

    function test_weighted_erc1155_pool_liquidates_and_claims_with_no_reserve_floor() public {
        uint256 underlyingTokenId = 3695;
        (WeightedRateERC1155CollectionPool weightedPool, ERC1155CollateralWrapper wrapper, TestERC1155 erc1155) =
            _deployWeightedERC1155Pool();

        (bytes memory receipt, bytes32 loanReceiptHash, uint256 wrappedTokenId) =
            _openWrappedERC1155Loan(weightedPool, wrapper, erc1155, underlyingTokenId);

        vm.warp(block.timestamp + DURATION + 1);
        bytes32 liquidationHash = _liquidationHash(address(wrapper), wrappedTokenId);
        weightedPool.liquidate(receipt);

        EnglishAuctionCollateralLiquidator.Auction memory auction =
            liquidator.auctions(liquidationHash, address(erc1155), underlyingTokenId);
        assertEq(uint256(weightedPool.loans(loanReceiptHash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated");
        assertEq(auction.quantity, 1, "underlying quantity auctioned");
        assertEq(auction.highestBid, 0, "auction starts with no bid");
        uint256 poolBalanceBeforeBid = currency.balanceOf(address(weightedPool));

        _fundAndApprove(highestBidder, 1);
        vm.prank(highestBidder);
        liquidator.bid(liquidationHash, address(erc1155), underlyingTokenId, 1);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(highestBidder);
        liquidator.claim(liquidationHash, address(erc1155), underlyingTokenId, receipt);

        assertEq(erc1155.balanceOf(highestBidder, underlyingTokenId), 1, "winner owns underlying ERC1155");
        assertEq(
            uint256(weightedPool.loans(loanReceiptHash)), uint256(Pool.LoanStatus.CollateralLiquidated), "loan closed"
        );
        assertEq(currency.balanceOf(address(weightedPool)), poolBalanceBeforeBid + 1, "pool receives highest bid");
    }

    function _startLiquidation(uint256 tokenId) internal returns (bytes32 liquidationHash) {
        nft.mint(source, tokenId);
        vm.prank(source);
        nft.approve(address(liquidator), tokenId);

        liquidationHash = keccak256(abi.encodePacked(block.chainid, address(nft), tokenId, block.timestamp));

        vm.prank(source);
        liquidator.liquidate(address(currency), address(nft), tokenId, "", LIQUIDATION_CONTEXT);
    }

    function _deployWeightedERC1155Pool()
        internal
        returns (WeightedRateERC1155CollectionPool weightedPool, ERC1155CollateralWrapper wrapper, TestERC1155 erc1155)
    {
        erc1155 = new TestERC1155("");
        wrapper = new ERC1155CollateralWrapper();

        address[] memory liquidatorWrappers = new address[](1);
        liquidatorWrappers[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator implementation = new EnglishAuctionCollateralLiquidator(liquidatorWrappers);
        bytes memory init = abi.encodeCall(
            EnglishAuctionCollateralLiquidator.initialize,
            (AUCTION_DURATION, TIME_EXTENSION_WINDOW, TIME_EXTENSION, MINIMUM_BID_BASIS_POINTS)
        );
        liquidator = EnglishAuctionCollateralLiquidator(address(new ERC1967Proxy(address(implementation), init)));

        address[] memory wrappers = new address[](1);
        wrappers[0] = address(wrapper);
        WeightedRateERC1155CollectionPool poolImplementation = new WeightedRateERC1155CollectionPool(
            address(liquidator), address(0), address(0), address(erc20DepositTokenImpl), wrappers, 0
        );

        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(erc1155);
        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);

        weightedPool = WeightedRateERC1155CollectionPool(
            address(
                new ERC1967Proxy(
                    address(poolImplementation),
                    abi.encodeCall(
                        WeightedRateERC1155CollectionPool.initialize,
                        (abi.encode(
                                collateralTokens, address(currency), address(new TestPriceOracle()), durations, rates
                            ))
                    )
                )
            )
        );
    }

    function _openWrappedERC1155Loan(
        WeightedRateERC1155CollectionPool weightedPool,
        ERC1155CollateralWrapper wrapper,
        TestERC1155 erc1155,
        uint256 underlyingTokenId
    ) internal returns (bytes memory receipt, bytes32 loanReceiptHash, uint256 wrappedTokenId) {
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
        wrappedTokenId = wrapper.mint(address(erc1155), tokenIds, quantities);

        bytes memory wrapperContext = abi.encode(address(erc1155), nonce, uint256(1), tokenIds, quantities);
        bytes memory options = _borrowOption(Pool.BorrowOptions.CollateralWrapperContext, wrapperContext);

        vm.prank(borrower);
        wrapper.approve(address(weightedPool), wrappedTokenId);

        vm.recordLogs();
        vm.prank(borrower);
        weightedPool.borrow(
            borrower, PRINCIPAL, DURATION, address(wrapper), wrappedTokenId, LENDER_DEPOSIT, _poolTicks(), options
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 loanTopic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(weightedPool) && logs[i].topics.length > 1 && logs[i].topics[0] == loanTopic)
            {
                return (abi.decode(logs[i].data, (bytes)), logs[i].topics[1], wrappedTokenId);
            }
        }
        revert("LoanOriginated event not found");
    }

    function _liquidationHash(address collateralToken, uint256 collateralTokenId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, collateralToken, collateralTokenId, block.timestamp));
    }

    function _borrowOption(Pool.BorrowOptions tag, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(uint256(tag)), uint16(data.length), data);
    }

    function _poolTicks() internal pure returns (uint128[] memory ticks) {
        ticks = new uint128[](1);
        ticks[0] = TICK;
    }

    function _fundAndApprove(address bidder, uint256 amount) internal {
        currency.mint(bidder, amount);
        vm.prank(bidder);
        currency.approve(address(liquidator), amount);
    }
}
