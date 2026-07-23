// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import {SimpleSignedPriceOracle} from "fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";

contract MockERC1271Signer {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    bool internal _shouldRevert;
    mapping(bytes32 => mapping(bytes => bool)) internal _validSignatures;

    function setValidSignature(bytes32 hash, bytes memory signature, bool valid) external {
        _validSignatures[hash][signature] = valid;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (_shouldRevert) revert("ERC1271_REVERT");
        return _validSignatures[hash][signature] ? MAGIC_VALUE : bytes4(0);
    }
}

contract TestableSimpleSignedPriceOracle is SimpleSignedPriceOracle {
    constructor(string memory name) SimpleSignedPriceOracle(name) {}

    function unsafeSetSignerForTest(address collateralToken, address signer) external {
        _priceOracleSigners[collateralToken] = signer;
    }
}

contract SimpleSignedPriceOracleGuardedTest is Test {
    event SignerUpdated(address indexed collateralToken, address signer);
    event CollateralPolicyUpdated(
        address indexed collateralToken,
        address indexed currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    );
    event TokenPolicyUpdated(
        address indexed collateralToken,
        uint256 indexed tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    );
    event CollateralEnabledUpdated(address indexed collateralToken, bool enabled);

    SimpleSignedPriceOracle internal oracle;
    MockERC1271Signer internal signerContract;
    address internal collateralToken;
    address internal currencyToken;
    address internal signer;

    string internal constant NAME = "All US Land";
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address token,uint256 tokenId,address currency,uint256 price,uint64 timestamp,uint64 duration)"
    );

    function setUp() public {
        vm.warp(1_000_000);
        collateralToken = makeAddr("collateralToken");
        currencyToken = makeAddr("currencyToken");
        signerContract = new MockERC1271Signer();
        signer = address(signerContract);
        oracle = new SimpleSignedPriceOracle(NAME);
        _configureCollateral();
        _configureToken(1, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        _enable(1);
    }

    function test_versionsAndOriginalDomainArePreservedForNewDeploy() public view {
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.IMPLEMENTATION_VERSION(), "1.4");
        assertEq(oracle.DOMAIN_VERSION(), "1.2");
    }

    function test_price_validErc1271QuotesReturnWeightedAverage() public {
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        _enableMany(_ids(1, 2));
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, 200_000, uint64(block.timestamp), 60);
        assertEq(
            oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(1, 3), abi.encode(quotes)), 175_000
        );
    }

    function test_price_validErc1271QuotePassesAfterSignerRotation() public {
        MockERC1271Signer contractSigner = new MockERC1271Signer();
        bytes memory signature = hex"cafe";
        SimpleSignedPriceOracle.Quote memory quote = _quote(1, 300_000, uint64(block.timestamp), 60);
        contractSigner.setValidSignature(_digest(quote), signature, true);
        oracle.setSigner(collateralToken, address(contractSigner));
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = SimpleSignedPriceOracle.SignedQuote(quote, signature);
        assertEq(oracle.price(collateralToken, currencyToken, _ids(1), _quantities(2), abi.encode(quotes)), 300_000);
    }

    function test_emitsPolicyEvents() public {
        address newCollateralToken = makeAddr("eventCollateralToken");
        address newSigner = address(new MockERC1271Signer());
        vm.expectEmit(true, false, false, true, address(oracle));
        emit SignerUpdated(newCollateralToken, newSigner);
        oracle.setSigner(newCollateralToken, newSigner);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit CollateralPolicyUpdated(newCollateralToken, currencyToken, 60, 90, 30 days);
        oracle.setCollateralPolicy(newCollateralToken, currencyToken, 60, 90, 30 days);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit TokenPolicyUpdated(newCollateralToken, 7, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        oracle.setTokenPolicy(newCollateralToken, 7, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit CollateralEnabledUpdated(newCollateralToken, true);
        oracle.setCollateralEnabled(newCollateralToken, true, _ids(7));
    }

    function test_gettersReturnPolicyReadbacks() public view {
        assertEq(oracle.priceOracleSigner(collateralToken), signer);
        SimpleSignedPriceOracle.CollateralPolicy memory policy = oracle.collateralPolicy(collateralToken);
        assertEq(policy.currencyToken, currencyToken);
        assertEq(policy.maxQuoteAge, 120);
        assertEq(policy.maxDuration, 300);
        assertEq(policy.maxReferenceAge, 30 days);
        assertEq(policy.enabledGeneration, 1);
        assertTrue(policy.enabled);
        assertTrue(policy.configured);
        SimpleSignedPriceOracle.TokenPolicy memory tokenPolicy = oracle.tokenPolicy(collateralToken, 1);
        assertEq(tokenPolicy.maxPrice, 1_000_000);
        assertEq(tokenPolicy.referencePrice, 500_000);
        assertEq(tokenPolicy.referenceUpdatedAt, uint64(block.timestamp));
        assertEq(tokenPolicy.maxDeviationBps, 10_000);
        assertTrue(tokenPolicy.configured);
    }

    function test_revert_missingCollateralConfig() public {
        SimpleSignedPriceOracle fresh = new SimpleSignedPriceOracle(NAME);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.MissingCollateralConfig.selector);
        fresh.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_marketDisabled() public {
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.MarketDisabled.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidLengths() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](0);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
        quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(1), abi.encode(quotes));
        vm.expectRevert(SimpleSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1, 2), abi.encode(quotes));
    }

    function test_revert_zeroQuantity() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.ZeroQuantity.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(0), abi.encode(quotes));
    }

    function test_revert_quoteTokenMismatch() public {
        SimpleSignedPriceOracle.Quote memory quote =
            SimpleSignedPriceOracle.Quote(makeAddr("wrong"), 1, currencyToken, 100_000, uint64(block.timestamp), 60);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _sign(quote);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteTokenMismatch.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_currencyTokenMismatch() public {
        address wrongCurrency = makeAddr("wrongCurrency");
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidCurrencyToken.selector);
        oracle.price(collateralToken, wrongCurrency, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quotePriceZero() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 0, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.QuotePriceZero.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteDurationTooLong() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 301);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteDurationTooLong.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByAge() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp - 121), 300);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteStale.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByDurationExpiry() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp - 20), 10);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteStale.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByFutureTimestamp() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp + 1), 60);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteStale.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidSigner() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] =
            SimpleSignedPriceOracle.SignedQuote(_quote(1, 100_000, uint64(block.timestamp), 60), bytes("badsignature"));
        vm.expectRevert(SimpleSignedPriceOracle.InvalidConfiguredSigner.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_eoaSignerStorageFailsClosed() public {
        TestableSimpleSignedPriceOracle fresh = new TestableSimpleSignedPriceOracle(NAME);
        uint256 signerPrivateKey = 0xA11CE;
        address eoaSigner = vm.addr(signerPrivateKey);
        fresh.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 30 days);
        fresh.setTokenPolicy(collateralToken, 1, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        fresh.unsafeSetSignerForTest(collateralToken, eoaSigner);
        fresh.setCollateralEnabled(collateralToken, true, _ids(1));
        SimpleSignedPriceOracle.Quote memory quote = _quote(1, 100_000, uint64(block.timestamp), 60);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, _digestFor(address(fresh), quote));
        bytes memory signature = abi.encodePacked(r, s, v);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = SimpleSignedPriceOracle.SignedQuote(quote, signature);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidConfiguredSigner.selector);
        fresh.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidSignerWhenErc1271Reverts() public {
        signerContract.setShouldRevert(true);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] =
            SimpleSignedPriceOracle.SignedQuote(_quote(1, 100_000, uint64(block.timestamp), 60), bytes("reverting"));
        vm.expectRevert(SimpleSignedPriceOracle.InvalidConfiguredSigner.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_missingTokenConfigDuringPrice() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(2, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.MissingTokenConfig.selector);
        oracle.price(collateralToken, currencyToken, _ids(2), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quotePriceExceedsCap() public {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 1_000_001, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.QuotePriceExceedsCap.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_referencePriceStale() public {
        vm.warp(block.timestamp + 31 days);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.ReferencePriceStale.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteDeviationTooHigh() public {
        _configureToken(1, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        _enable(1);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 600_001, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.QuoteDeviationTooHigh.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_enableRequiresLiveTokenIds() public {
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        vm.expectRevert(SimpleSignedPriceOracle.TokenIdsRequired.selector);
        oracle.setCollateralEnabled(collateralToken, true, new uint256[](0));
    }

    function test_revert_partialConfigCannotEnable() public {
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        vm.expectRevert(SimpleSignedPriceOracle.MissingTokenConfig.selector);
        oracle.setCollateralEnabled(collateralToken, true, _ids(1, 2));
    }

    function test_revert_newTokenPolicyRequiresExplicitReenable() public {
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(2, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(SimpleSignedPriceOracle.TokenNotEnabled.selector);
        oracle.price(collateralToken, currencyToken, _ids(2), _quantities(1), abi.encode(quotes));
        _enableMany(_ids(1, 2));
        assertEq(oracle.price(collateralToken, currencyToken, _ids(2), _quantities(1), abi.encode(quotes)), 100_000);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        _enable(2);
        vm.expectRevert(SimpleSignedPriceOracle.TokenNotEnabled.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_setCollateralEnabledMissingCollateralConfig() public {
        vm.expectRevert(SimpleSignedPriceOracle.MissingCollateralConfig.selector);
        oracle.setCollateralEnabled(makeAddr("newCollateral"), true, _ids(1));
    }

    function test_revert_adminValidation() public {
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setSigner(address(0), signer);
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setSigner(collateralToken, address(0));
        vm.expectRevert(SimpleSignedPriceOracle.InvalidSignerContract.selector);
        oracle.setSigner(collateralToken, makeAddr("eoa"));
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralPolicy(address(0), currencyToken, 120, 300, 30 days);
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralPolicy(collateralToken, address(0), 120, 300, 30 days);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidCollateralPolicy.selector);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 0, 300, 30 days);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidCollateralPolicy.selector);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 0, 30 days);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidCollateralPolicy.selector);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 0);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidCollateralPolicy.selector);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 30 days + 1);
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setTokenPolicy(address(0), 3, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidDeviationBps.selector);
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, uint64(block.timestamp), 10_001);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidTokenPolicy.selector);
        oracle.setTokenPolicy(collateralToken, 3, 0, 500_000, uint64(block.timestamp), 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidTokenPolicy.selector);
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 0, uint64(block.timestamp), 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidTokenPolicy.selector);
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, 0, 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidTokenPolicy.selector);
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, uint64(block.timestamp + 1), 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.InvalidTokenPolicy.selector);
        oracle.setTokenPolicy(collateralToken, 3, 500_000, 500_001, uint64(block.timestamp), 1_000);
        vm.expectRevert(SimpleSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralEnabled(address(0), false, new uint256[](0));
    }

    function test_revert_renounceOwnershipDisabled() public {
        vm.expectRevert(SimpleSignedPriceOracle.OwnershipRenounceDisabled.selector);
        oracle.renounceOwnership();
    }

    function test_revert_onlyOwnerCanConfigure() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setSigner(collateralToken, signer);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 30 days);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setTokenPolicy(collateralToken, 1, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setCollateralEnabled(collateralToken, true, _ids(1));
        vm.stopPrank();
    }

    function test_weightedAggregateExercisesCapDeviationAndValidPaths() public {
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        _enableMany(_ids(1, 2));
        _expectTwoQuoteRevert(
            1_000_001, 500_000, abi.encodeWithSelector(SimpleSignedPriceOracle.QuotePriceExceedsCap.selector)
        );
        _expectTwoQuoteRevert(
            500_000, 1_000_001, abi.encodeWithSelector(SimpleSignedPriceOracle.QuotePriceExceedsCap.selector)
        );
        _expectTwoQuoteRevert(
            500_000, 550_001, abi.encodeWithSelector(SimpleSignedPriceOracle.QuoteDeviationTooHigh.selector)
        );
        _expectTwoQuoteRevert(
            500_000, 449_999, abi.encodeWithSelector(SimpleSignedPriceOracle.QuoteDeviationTooHigh.selector)
        );
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, 600_000, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, 500_000, uint64(block.timestamp), 60);
        assertEq(
            oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(2, 3), abi.encode(quotes)), 540_000
        );
    }

    function testFuzz_weightedAggregateCannotExceedConfiguredCaps(
        uint128 rawPriceA,
        uint128 rawPriceB,
        uint64 rawQuantityA,
        uint64 rawQuantityB
    ) public {
        uint256 priceA = bound(uint256(rawPriceA), 1, 1_500_000);
        uint256 priceB = bound(uint256(rawPriceB), 1, 1_500_000);
        uint256 quantityA = bound(uint256(rawQuantityA), 1, 1_000_000);
        uint256 quantityB = bound(uint256(rawQuantityB), 1, 1_000_000);
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        _enableMany(_ids(1, 2));
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, priceA, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, priceB, uint64(block.timestamp), 60);
        if (priceA > 1_000_000) {
            vm.expectRevert(abi.encodeWithSelector(SimpleSignedPriceOracle.QuotePriceExceedsCap.selector));
        } else if (priceB > 1_000_000) {
            vm.expectRevert(abi.encodeWithSelector(SimpleSignedPriceOracle.QuotePriceExceedsCap.selector));
        } else if (priceB < 450_000 || priceB > 550_000) {
            vm.expectRevert(abi.encodeWithSelector(SimpleSignedPriceOracle.QuoteDeviationTooHigh.selector));
        } else {
            uint256 expected = (priceA * quantityA + priceB * quantityB) / (quantityA + quantityB);
            assertEq(
                oracle.price(
                    collateralToken, currencyToken, _ids(1, 2), _quantities(quantityA, quantityB), abi.encode(quotes)
                ),
                expected
            );
            assertLe(expected, 1_000_000);
            return;
        }
        oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(quantityA, quantityB), abi.encode(quotes));
    }

    function _expectTwoQuoteRevert(uint256 priceA, uint256 priceB, bytes memory expectedRevertData) internal {
        SimpleSignedPriceOracle.SignedQuote[] memory quotes = new SimpleSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, priceA, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, priceB, uint64(block.timestamp), 60);
        vm.expectRevert(expectedRevertData);
        oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(1, 1), abi.encode(quotes));
    }

    function _configureCollateral() internal {
        oracle.setSigner(collateralToken, signer);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 30 days);
    }

    function _configureToken(
        uint256 tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    ) internal {
        oracle.setTokenPolicy(collateralToken, tokenId, maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps);
    }

    function _enable(uint256 tokenId) internal {
        oracle.setCollateralEnabled(collateralToken, true, _ids(tokenId));
    }

    function _enableMany(uint256[] memory tokenIds) internal {
        oracle.setCollateralEnabled(collateralToken, true, tokenIds);
    }

    function _signedQuote(uint256 tokenId, uint256 quotePrice, uint64 timestamp, uint64 duration)
        internal
        returns (SimpleSignedPriceOracle.SignedQuote memory)
    {
        return _sign(_quote(tokenId, quotePrice, timestamp, duration));
    }

    function _quote(uint256 tokenId, uint256 quotePrice, uint64 timestamp, uint64 duration)
        internal
        view
        returns (SimpleSignedPriceOracle.Quote memory)
    {
        return SimpleSignedPriceOracle.Quote(collateralToken, tokenId, currencyToken, quotePrice, timestamp, duration);
    }

    function _sign(SimpleSignedPriceOracle.Quote memory quote)
        internal
        returns (SimpleSignedPriceOracle.SignedQuote memory)
    {
        bytes memory signature = abi.encodePacked(
            quote.token, quote.tokenId, quote.currency, quote.price, quote.timestamp, quote.duration
        );
        signerContract.setValidSignature(_digest(quote), signature, true);
        return SimpleSignedPriceOracle.SignedQuote(quote, signature);
    }

    function _digest(SimpleSignedPriceOracle.Quote memory quote) internal view returns (bytes32) {
        return _digestFor(address(oracle), quote);
    }

    function _digestFor(address verifyingContract, SimpleSignedPriceOracle.Quote memory quote)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(oracle.DOMAIN_VERSION())),
                block.chainid,
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH, quote.token, quote.tokenId, quote.currency, quote.price, quote.timestamp, quote.duration
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _quantities(uint256 a) internal pure returns (uint256[] memory quantities) {
        quantities = new uint256[](1);
        quantities[0] = a;
    }

    function _quantities(uint256 a, uint256 b) internal pure returns (uint256[] memory quantities) {
        quantities = new uint256[](2);
        quantities[0] = a;
        quantities[1] = b;
    }
}
