// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";

import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";

contract FabricaLendingPoolAuctionNoReserveTest is Test {
    EnglishAuctionCollateralLiquidator internal liquidator;
    TestERC20 internal currency;
    TestERC721 internal nft;

    address internal source = makeAddr("liquidation-source");
    address internal firstBidder = makeAddr("first-bidder");
    address internal highestBidder = makeAddr("highest-bidder");

    uint64 internal constant AUCTION_DURATION = 1 days;
    uint64 internal constant TIME_EXTENSION_WINDOW = 15 minutes;
    uint64 internal constant TIME_EXTENSION = 30 minutes;
    uint64 internal constant MINIMUM_BID_BASIS_POINTS = 500;
    bytes internal constant LIQUIDATION_CONTEXT = hex"3695";

    function setUp() public {
        vm.warp(1_700_000_000);

        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");

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

    function _startLiquidation(uint256 tokenId) internal returns (bytes32 liquidationHash) {
        nft.mint(source, tokenId);
        vm.prank(source);
        nft.approve(address(liquidator), tokenId);

        liquidationHash = keccak256(abi.encodePacked(block.chainid, address(nft), tokenId, block.timestamp));

        vm.prank(source);
        liquidator.liquidate(address(currency), address(nft), tokenId, "", LIQUIDATION_CONTEXT);
    }

    function _fundAndApprove(address bidder, uint256 amount) internal {
        currency.mint(bidder, amount);
        vm.prank(bidder);
        currency.approve(address(liquidator), amount);
    }
}
