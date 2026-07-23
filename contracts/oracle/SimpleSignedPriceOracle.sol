// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IPriceOracle.sol";

/**
 * @title Simple Signed Price Oracle
 * @author MetaStreet Labs
 */
contract SimpleSignedPriceOracle is Ownable2Step, EIP712, IPriceOracle {
    /**************************************************************************/
    /* Constants */
    /**************************************************************************/

    /**
     * @notice Basis point denominator used for deviation checks
     */
    uint256 public constant BASIS_POINTS = 10_000;

    /**
     * @notice Maximum owner-configurable reference price age
     */
    uint64 public constant MAX_REFERENCE_AGE = 30 days;

    /**
     * @notice Quote EIP-712 typehash
     */
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256(
            "Quote(address token,uint256 tokenId,address currency,uint256 price,uint64 timestamp,uint64 duration)"
        );

    /**************************************************************************/
    /* Errors */
    /**************************************************************************/

    /**
     * @notice Invalid length
     */
    error InvalidLength();

    /**
     * @notice Zero address
     */
    error ZeroAddress();

    /**
     * @notice Zero token quantity
     */
    error ZeroQuantity();

    /**
     * @notice Market disabled
     */
    error MarketDisabled();

    /**
     * @notice Missing collateral configuration
     */
    error MissingCollateralConfig();

    /**
     * @notice Missing token configuration
     */
    error MissingTokenConfig();

    /**
     * @notice Token policy is not enabled for the current collateral generation
     */
    error TokenNotEnabled();

    /**
     * @notice Quote token, token ID, or currency mismatch
     */
    error QuoteTokenMismatch();

    /**
     * @notice Quote price is zero
     */
    error QuotePriceZero();

    /**
     * @notice Quote duration is longer than policy allows
     */
    error QuoteDurationTooLong();

    /**
     * @notice Quote timestamp is outside freshness bounds
     */
    error QuoteStale();

    /**
     * @notice Invalid configured signer
     */
    error InvalidConfiguredSigner();

    /**
     * @notice Invalid currency token
     */
    error InvalidCurrencyToken();

    /**
     * @notice Quote price exceeds hard cap
     */
    error QuotePriceExceedsCap();

    /**
     * @notice Reference price is stale
     */
    error ReferencePriceStale();

    /**
     * @notice Quote deviation exceeds policy
     */
    error QuoteDeviationTooHigh();

    /**
     * @notice Invalid collateral policy
     */
    error InvalidCollateralPolicy();

    /**
     * @notice Invalid token policy
     */
    error InvalidTokenPolicy();

    /**
     * @notice Invalid deviation in basis points
     */
    error InvalidDeviationBps();

    /**
     * @notice Live token IDs are required when enabling a collateral market
     */
    error TokenIdsRequired();

    /**
     * @notice Signer must be a contract
     */
    error InvalidSignerContract();

    /**
     * @notice Ownership renounce disabled
     */
    error OwnershipRenounceDisabled();

    /**************************************************************************/
    /* Events */
    /**************************************************************************/

    /**
     * @notice Emitted when price oracle signer is set
     * @param collateralToken Collateral token
     * @param signer Signer
     */
    event SignerUpdated(address indexed collateralToken, address signer);

    /**
     * @notice Emitted when collateral policy is set
     * @param collateralToken Collateral token
     * @param currencyToken Currency token
     * @param maxQuoteAge Maximum quote age
     * @param maxDuration Maximum quote duration
     * @param maxReferenceAge Maximum reference price age
     */
    event CollateralPolicyUpdated(
        address indexed collateralToken,
        address indexed currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    );

    /**
     * @notice Emitted when token policy is set
     * @param collateralToken Collateral token
     * @param tokenId Token ID
     * @param maxPrice Hard maximum signed price
     * @param referencePrice Reference price
     * @param referenceUpdatedAt Reference price update timestamp
     * @param maxDeviationBps Maximum deviation in basis points
     */
    event TokenPolicyUpdated(
        address indexed collateralToken,
        uint256 indexed tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    );

    /**
     * @notice Emitted when a collateral market is enabled or disabled
     * @param collateralToken Collateral token
     * @param enabled True if enabled
     */
    event CollateralEnabledUpdated(address indexed collateralToken, bool enabled);

    /**************************************************************************/
    /* Structures */
    /**************************************************************************/

    /**
     * @notice Quote
     * @param token Token
     * @param tokenId Token ID
     * @param currency Currency
     * @param price Price
     * @param timestamp Timestamp
     * @param duration Duration validity
     */
    struct Quote {
        address token;
        uint256 tokenId;
        address currency;
        uint256 price;
        uint64 timestamp;
        uint64 duration;
    }

    /**
     * @notice Quote with signature
     * @param quote Quote
     * @param signature Signature payload validated by the configured ERC-1271 signer
     */
    struct SignedQuote {
        Quote quote;
        bytes signature;
    }

    /**
     * @notice Collateral-wide price policy
     * @param currencyToken Currency token accepted for this collateral
     * @param maxQuoteAge Maximum quote age
     * @param maxDuration Maximum quote duration
     * @param maxReferenceAge Maximum token reference price age
     * @param enabledGeneration Current enabled token policy generation
     * @param enabled True if market is enabled
     * @param configured True if policy is configured
     */
    struct CollateralPolicy {
        address currencyToken;
        uint64 maxQuoteAge;
        uint64 maxDuration;
        uint64 maxReferenceAge;
        uint64 enabledGeneration;
        bool enabled;
        bool configured;
    }

    /**
     * @notice Token-level price policy
     * @param maxPrice Hard maximum signed price
     * @param referencePrice Reference price
     * @param referenceUpdatedAt Reference price update timestamp
     * @param maxDeviationBps Maximum deviation in basis points
     * @param configured True if policy is configured
     */
    struct TokenPolicy {
        uint256 maxPrice;
        uint256 referencePrice;
        uint64 referenceUpdatedAt;
        uint16 maxDeviationBps;
        bool configured;
    }

    /**************************************************************************/
    /* State */
    /**************************************************************************/

    /**
     * @notice Initialized boolean
     */
    bool private _initialized;

    /**
     * @notice Mapping of collection to price oracle signers
     */
    mapping(address => address) internal _priceOracleSigners;

    /**
     * @notice Mapping of collection to collateral policy
     */
    mapping(address => CollateralPolicy) internal _collateralPolicies;

    /**
     * @notice Mapping of collection to token policies
     */
    mapping(address => mapping(uint256 => TokenPolicy)) internal _tokenPolicies;

    /**
     * @notice Mapping of collection and token ID to enabled generation
     */
    mapping(address => mapping(uint256 => uint64)) internal _tokenPolicyGenerations;

    /**************************************************************************/
    /* Constructor */
    /**************************************************************************/

    /**
     * @notice Simple Signed Price Oracle constructor
     * @param name_ Domain separator name
     */
    constructor(string memory name_) EIP712(name_, DOMAIN_VERSION()) {
        /* Disable initialization of implementation contract */
        _initialized = true;
    }

    /**************************************************************************/
    /* Initializer */
    /**************************************************************************/

    /**
     * @notice Initializer
     */
    function initialize(address owner) external {
        require(!_initialized, "Already initialized");

        _initialized = true;
        _transferOwnership(owner);
    }

    /**************************************************************************/
    /* Internal Helpers */
    /**************************************************************************/

    /**
     * @notice Verify quote and signer
     * @param collateralToken Collateral token
     * @param collateralTokenId Collateral token ID
     * @param poolCurrency Pool currency
     * @param signedQuote Signed quote
     */
    function _verifyQuote(
        address collateralToken,
        uint256 collateralTokenId,
        address poolCurrency,
        SignedQuote memory signedQuote,
        CollateralPolicy memory policy
    ) internal view returns (uint256) {
        Quote memory quote = signedQuote.quote;

        /* Validate quote token, token ID, and currency */
        if (collateralToken != quote.token || collateralTokenId != quote.tokenId || poolCurrency != quote.currency) {
            revert QuoteTokenMismatch();
        }

        /* Validate quote price is non-zero */
        if (quote.price == 0) revert QuotePriceZero();

        /* Validate quote duration and timestamp */
        if (quote.duration > policy.maxDuration) revert QuoteDurationTooLong();
        _validateQuoteFresh(quote.timestamp, quote.duration, policy.maxQuoteAge);

        /* Validate signer */
        address signerAddress = _priceOracleSigners[collateralToken];
        if (
            signerAddress.code.length == 0
                || !SignatureChecker.isValidERC1271SignatureNow(signerAddress, _quoteDigest(quote), signedQuote.signature)
        ) {
            revert InvalidConfiguredSigner();
        }

        /* Validate token policy */
        TokenPolicy memory tokenPolicy_ = _tokenPolicies[collateralToken][collateralTokenId];
        if (!tokenPolicy_.configured) revert MissingTokenConfig();
        if (_tokenPolicyGenerations[collateralToken][collateralTokenId] != policy.enabledGeneration) {
            revert TokenNotEnabled();
        }
        _validateCapAndReference(quote.price, tokenPolicy_, policy.maxReferenceAge);

        return quote.price;
    }

    /**
     * @notice Hash quote for EIP-712 verification
     * @param quote Quote
     * @return Quote digest
     */
    function _quoteDigest(Quote memory quote) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        QUOTE_TYPEHASH,
                        quote.token,
                        quote.tokenId,
                        quote.currency,
                        quote.price,
                        quote.timestamp,
                        quote.duration
                    )
                )
            );
    }

    /**
     * @notice Require collateral market enabled
     * @param collateralToken Collateral token
     * @return policy Collateral policy
     */
    function _requireEnabledCollateral(address collateralToken) internal view returns (CollateralPolicy memory policy) {
        policy = _collateralPolicies[collateralToken];
        if (!policy.configured || _priceOracleSigners[collateralToken] == address(0) || policy.currencyToken == address(0)) {
            revert MissingCollateralConfig();
        }
        if (!policy.enabled) revert MarketDisabled();
    }

    /**
     * @notice Validate all live token IDs are configured before enabling collateral
     * @param collateralToken Collateral token
     * @param liveTokenIds Live token IDs
     */
    function _validateCollateralReady(address collateralToken, uint256[] calldata liveTokenIds) internal view {
        CollateralPolicy memory policy = _collateralPolicies[collateralToken];
        if (!policy.configured || _priceOracleSigners[collateralToken] == address(0) || policy.currencyToken == address(0)) {
            revert MissingCollateralConfig();
        }
        if (liveTokenIds.length == 0) revert TokenIdsRequired();
        for (uint256 i; i < liveTokenIds.length; i++) {
            TokenPolicy memory tokenPolicy_ = _tokenPolicies[collateralToken][liveTokenIds[i]];
            if (!tokenPolicy_.configured) revert MissingTokenConfig();
            _validateReferenceFresh(tokenPolicy_, policy.maxReferenceAge);
        }
    }

    /**
     * @notice Validate quote timestamp
     * @param timestamp Quote timestamp
     * @param duration Quote duration
     * @param maxQuoteAge Maximum quote age
     */
    function _validateQuoteFresh(uint64 timestamp, uint64 duration, uint64 maxQuoteAge) internal view {
        uint256 currentTimestamp = block.timestamp;
        if (timestamp > currentTimestamp) revert QuoteStale();
        if (currentTimestamp - timestamp > maxQuoteAge) revert QuoteStale();
        if (uint256(timestamp) + duration < currentTimestamp) {
            revert QuoteStale();
        }
    }

    /**
     * @notice Validate token cap and reference price
     * @param quotePrice Quote price
     * @param tokenPolicy_ Token policy
     * @param maxReferenceAge Maximum reference age
     */
    function _validateCapAndReference(
        uint256 quotePrice,
        TokenPolicy memory tokenPolicy_,
        uint64 maxReferenceAge
    ) internal view {
        if (quotePrice > tokenPolicy_.maxPrice) {
            revert QuotePriceExceedsCap();
        }
        _validateReferenceFresh(tokenPolicy_, maxReferenceAge);
        uint256 delta = quotePrice > tokenPolicy_.referencePrice
            ? quotePrice - tokenPolicy_.referencePrice
            : tokenPolicy_.referencePrice - quotePrice;
        uint256 allowedDelta = Math.mulDiv(tokenPolicy_.referencePrice, tokenPolicy_.maxDeviationBps, BASIS_POINTS);
        if (delta > allowedDelta) {
            revert QuoteDeviationTooHigh();
        }
    }

    /**
     * @notice Validate token reference price freshness
     * @param tokenPolicy_ Token policy
     * @param maxReferenceAge Maximum reference age
     */
    function _validateReferenceFresh(TokenPolicy memory tokenPolicy_, uint64 maxReferenceAge) internal view {
        uint256 currentTimestamp = block.timestamp;
        if (
            tokenPolicy_.referenceUpdatedAt > currentTimestamp
                || currentTimestamp - tokenPolicy_.referenceUpdatedAt > maxReferenceAge
        ) {
            revert ReferencePriceStale();
        }
    }

    /**************************************************************************/
    /* Getters */
    /**************************************************************************/

    /**
     * @notice Get price oracle implementation version
     * @return Price oracle implementation version
     */
    function IMPLEMENTATION_VERSION() public pure returns (string memory) {
        return "1.4";
    }

    /**
     * @notice Get signing domain version
     * @return Signing domain version
     */
    function DOMAIN_VERSION() public pure returns (string memory) {
        return "1.2";
    }

    /**
     * @notice Get price oracle signer for collateral token
     * @param collateralToken Collateral token
     * @return Price oracle signer
     */
    function priceOracleSigner(address collateralToken) external view returns (address) {
        return _priceOracleSigners[collateralToken];
    }

    /**
     * @notice Get collateral policy
     * @param collateralToken Collateral token
     * @return Collateral policy
     */
    function collateralPolicy(address collateralToken) external view returns (CollateralPolicy memory) {
        return _collateralPolicies[collateralToken];
    }

    /**
     * @notice Get token policy
     * @param collateralToken Collateral token
     * @param tokenId Token ID
     * @return Token policy
     */
    function tokenPolicy(address collateralToken, uint256 tokenId) external view returns (TokenPolicy memory) {
        return _tokenPolicies[collateralToken][tokenId];
    }

    /**************************************************************************/
    /* API */
    /**************************************************************************/

    /**
     * @inheritdoc IPriceOracle
     */
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory collateralTokenIds,
        uint256[] memory collateralTokenQuantities,
        bytes calldata oracleContext
    ) external view override returns (uint256) {
        /* Decode oracle context into a SignedQuote array */
        SignedQuote[] memory signedQuotes = abi.decode(oracleContext, (SignedQuote[]));

        /* Validate arrays have equal lengths */
        if (signedQuotes.length == 0 || signedQuotes.length != collateralTokenIds.length) revert InvalidLength();
        if (collateralTokenIds.length != collateralTokenQuantities.length) revert InvalidLength();

        /* Validate collateral is fully configured and enabled */
        CollateralPolicy memory policy = _requireEnabledCollateral(collateralToken);
        if (policy.currencyToken != currencyToken) {
            revert InvalidCurrencyToken();
        }

        /* Validate and aggregate oracle prices */
        uint256 totalOraclePrice = 0;
        uint256 count = 0;
        for (uint256 i; i < collateralTokenIds.length; i++) {
            uint256 quantity = collateralTokenQuantities[i];
            if (quantity == 0) revert ZeroQuantity();

            /* Validate quote and signer */
            uint256 quotePrice = _verifyQuote(collateralToken, collateralTokenIds[i], currencyToken, signedQuotes[i], policy);

            /* Update total oracle price and collateral token count */
            totalOraclePrice += quotePrice * quantity;
            count += quantity;
        }

        /* Return average collateral token price */
        return totalOraclePrice / count;
    }

    /**************************************************************************/
    /* Admin API */
    /**************************************************************************/

    /**
     * @notice Set price oracle signer for collateral token
     *
     * Emits a {SignerUpdated} event.
     *
     * @param collateralToken Collateral token
     * @param signer Signer
     */
    function setSigner(address collateralToken, address signer) external onlyOwner {
        if (collateralToken == address(0) || signer == address(0)) revert ZeroAddress();
        if (signer.code.length == 0) revert InvalidSignerContract();
        _priceOracleSigners[collateralToken] = signer;

        emit SignerUpdated(collateralToken, signer);
    }

    /**
     * @notice Set collateral policy
     *
     * Emits a {CollateralPolicyUpdated} event.
     *
     * @param collateralToken Collateral token
     * @param currencyToken Currency token
     * @param maxQuoteAge Maximum quote age
     * @param maxDuration Maximum quote duration
     * @param maxReferenceAge Maximum token reference price age
     */
    function setCollateralPolicy(
        address collateralToken,
        address currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    ) external onlyOwner {
        if (collateralToken == address(0) || currencyToken == address(0)) revert ZeroAddress();
        if (maxQuoteAge == 0 || maxDuration == 0 || maxReferenceAge == 0 || maxReferenceAge > MAX_REFERENCE_AGE) {
            revert InvalidCollateralPolicy();
        }
        CollateralPolicy storage policy = _collateralPolicies[collateralToken];
        policy.currencyToken = currencyToken;
        policy.maxQuoteAge = maxQuoteAge;
        policy.maxDuration = maxDuration;
        policy.maxReferenceAge = maxReferenceAge;
        policy.configured = true;
        emit CollateralPolicyUpdated(collateralToken, currencyToken, maxQuoteAge, maxDuration, maxReferenceAge);
    }

    /**
     * @notice Set token policy
     *
     * Emits a {TokenPolicyUpdated} event.
     *
     * @param collateralToken Collateral token
     * @param tokenId Token ID
     * @param maxPrice Hard maximum signed price
     * @param referencePrice Reference price
     * @param referenceUpdatedAt Reference price update timestamp
     * @param maxDeviationBps Maximum deviation in basis points
     */
    function setTokenPolicy(
        address collateralToken,
        uint256 tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    ) external onlyOwner {
        if (collateralToken == address(0)) revert ZeroAddress();
        if (maxDeviationBps > BASIS_POINTS) revert InvalidDeviationBps();
        uint256 currentTimestamp = block.timestamp;
        if (
            maxPrice == 0 || referencePrice == 0 || referencePrice > maxPrice || referenceUpdatedAt == 0
                || referenceUpdatedAt > currentTimestamp
        ) {
            revert InvalidTokenPolicy();
        }
        _tokenPolicies[collateralToken][tokenId] =
            TokenPolicy(maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps, true);
        emit TokenPolicyUpdated(collateralToken, tokenId, maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps);
    }

    /**
     * @notice Enable or disable collateral market
     *
     * Emits a {CollateralEnabledUpdated} event.
     *
     * @param collateralToken Collateral token
     * @param enabled True if enabled
     * @param liveTokenIds Live token IDs that must be configured before enabling
     */
    function setCollateralEnabled(address collateralToken, bool enabled, uint256[] calldata liveTokenIds)
        external
        onlyOwner
    {
        if (collateralToken == address(0)) revert ZeroAddress();
        CollateralPolicy storage policy = _collateralPolicies[collateralToken];
        if (enabled) {
            _validateCollateralReady(collateralToken, liveTokenIds);
            policy.enabledGeneration += 1;
            for (uint256 i; i < liveTokenIds.length; i++) {
                _tokenPolicyGenerations[collateralToken][liveTokenIds[i]] = policy.enabledGeneration;
            }
        }
        policy.enabled = enabled;
        emit CollateralEnabledUpdated(collateralToken, enabled);
    }

    /**
     * @notice Disable ownership renounce so oracle policy recovery remains available
     */
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenounceDisabled();
    }
}
