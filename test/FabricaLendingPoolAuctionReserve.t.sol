// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "fabrica-lending-pools/Pool.sol";
import "fabrica-lending-pools/interfaces/IPool.sol";
import "fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import "fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";
import "./concretes/TestLiquidatablePool.sol";

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

    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);

    function setUp() public {
        vm.warp(1_700_000_000);

        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = _deployLiquidator();
    }

    function _deployLiquidator() internal returns (EnglishAuctionCollateralLiquidator) {
        address[] memory wrappers = new address[](0);
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

    function test_liquidator_rejects_legacy_liquidate_without_reserve() public {
        vm.expectRevert(EnglishAuctionCollateralLiquidator.ReserveRequired.selector);
        liquidator.liquidate(address(currency), address(nft), 1, "", LIQUIDATION_CONTEXT);
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
}
