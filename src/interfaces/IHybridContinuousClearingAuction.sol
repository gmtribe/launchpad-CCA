// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Checkpoint} from '../libraries/CheckpointLib.sol';
import {ValueX7} from '../libraries/ValueX7Lib.sol';
import {IBidStorage} from './IBidStorage.sol';
import {ICheckpointStorage} from './ICheckpointStorage.sol';
import {IFixedPriceStorage} from './IFixedPriceStorage.sol';
import {IStepStorage} from './IStepStorage.sol';
import {ITickStorage} from './ITickStorage.sol';
import {ITokenCurrencyStorage} from './ITokenCurrencyStorage.sol';
import {IValidationHook} from './IValidationHook.sol';
import {IDistributionContract} from './external/IDistributionContract.sol';

/// @notice Parameters for the hybrid auction V2
/// @dev Uses token allocation instead of MPS threshold for fixed price phase
struct HybridAuctionParameters {
    address currency; // Token to raise funds in. Use address(0) for ETH
    address tokensRecipient; // Address to receive leftover tokens
    address fundsRecipient; // Address to receive all raised funds
    uint64 startBlock; // Block which the first step starts
    uint64 endBlock; // When the auction finishes
    uint64 claimBlock; // Block when the auction can be claimed
    uint256 tickSpacing; // Fixed granularity for prices
    address validationHook; // Optional hook called before a bid
    uint256 floorPrice; // Floor price (also used as fixed price in V2)
    uint128 requiredCurrencyRaised; // Amount of currency required for graduation
    bytes auctionStepsData; // Packed bytes describing token issuance schedule for CCA phase
    uint128 fixedPhaseTokenAllocation; // Number of tokens allocated to fixed price phase (0 for pure CCA)
    uint64 fixedPriceBlockDuration; // Number of blocks for fixed price phase (0 to only use token allocation)
}

/// @notice Interface for the HybridContinuousClearingAuction contract V2
interface IHybridContinuousClearingAuction is
    IDistributionContract,
    ICheckpointStorage,
    IFixedPriceStorage,
    ITickStorage,
    IStepStorage,
    ITokenCurrencyStorage,
    IBidStorage
{
    /// @notice Error thrown when the amount received is invalid
    error InvalidTokenAmountReceived();
    /// @notice Error thrown when an invalid value is deposited
    error InvalidAmount();
    /// @notice Error thrown when the bid owner is the zero address
    error BidOwnerCannotBeZeroAddress();
    /// @notice Error thrown when the bid price is below the clearing price (CCA phase)
    error BidMustBeAboveClearingPrice();
    /// @notice Error thrown when the bid price is below the fixed price (fixed price phase)
    error BidBelowFixedPrice();
    /// @notice Error thrown when the bid price is too high given the auction's total supply
    error InvalidBidPriceTooHigh(uint256 maxPrice, uint256 maxBidPrice);
    /// @notice Error thrown when the bid amount is too small
    error BidAmountTooSmall();
    /// @notice Error thrown when msg.value is non zero when currency is not ETH
    error CurrencyIsNotNative();
    /// @notice Error thrown when the auction is not started
    error AuctionNotStarted();
    /// @notice Error thrown when the tokens required for the auction have not been received
    error TokensNotReceived();
    /// @notice Error thrown when the claim block is before the end block
    error ClaimBlockIsBeforeEndBlock();
    /// @notice Error thrown when the floor price plus tick spacing is greater than the maximum bid price
    error FloorPriceAndTickSpacingGreaterThanMaxBidPrice(uint256 nextTick, uint256 maxBidPrice);
    /// @notice Error thrown when the bid has already been exited
    error BidAlreadyExited();
    /// @notice Error thrown when the bid cannot be exited
    error CannotExitBid();
    /// @notice Error thrown when the bid cannot be partially exited before the end block
    error CannotPartiallyExitBidBeforeEndBlock();
    /// @notice Error thrown when the last fully filled checkpoint hint is invalid
    error InvalidLastFullyFilledCheckpointHint();
    /// @notice Error thrown when the outbid block checkpoint hint is invalid
    error InvalidOutbidBlockCheckpointHint();
    /// @notice Error thrown when the bid is not claimable
    error NotClaimable();
    /// @notice Error thrown when the bids are not owned by the same owner
    error BatchClaimDifferentOwner(address expectedOwner, address receivedOwner);
    /// @notice Error thrown when the bid has not been exited
    error BidNotExited();
    /// @notice Error thrown when the bid cannot be partially exited before the auction has graduated
    error CannotPartiallyExitBidBeforeGraduation();
    /// @notice Error thrown when the auction is not over
    error AuctionIsNotOver();
    /// @notice Error thrown when the bid is too large
    error InvalidBidUnableToClear();
    /// @notice Error thrown when the auction has sold the entire total supply of tokens
    error AuctionSoldOut();
    /// @notice Error thrown when all tokens are sold in fixed phase and none remain for CCA
    error NoTokensRemainingForCCA();

    /// @notice Emitted when the tokens are received
    event TokensReceived(uint256 totalSupply);

    /// @notice Emitted when a bid is submitted (CCA phase)
    event BidSubmitted(uint256 indexed id, address indexed owner, uint256 price, uint128 amount);

    /// @notice Emitted when a fixed price order is filled
    event FixedPriceOrderFilled(
        uint256 indexed id,
        address indexed owner,
        uint128 tokensFilled,
        uint128 currencySpent,
        uint128 refund
    );

    /// @notice Emitted when a new checkpoint is created
    event CheckpointUpdated(uint256 blockNumber, uint256 clearingPrice, uint24 cumulativeMps);

    /// @notice Emitted when the clearing price is updated
    event ClearingPriceUpdated(uint256 blockNumber, uint256 clearingPrice);

    // /// @notice Emitted when the next active tick is updated
    // event NextActiveTickUpdated(uint256 price);

    /// @notice Emitted when a bid is exited
    event BidExited(uint256 indexed bidId, address indexed owner, uint256 tokensFilled, uint256 currencyRefunded);

    /// @notice Emitted when a bid is claimed
    event TokensClaimed(uint256 indexed bidId, address indexed owner, uint256 tokensFilled);

    /// @notice Submit a new bid or order
    /// @dev During fixed price phase, this places an order at fixed price
    /// @dev During CCA phase, this submits a standard bid
    /// @param maxPrice The maximum price (must be >= FIXED_PRICE in fixed phase, > clearingPrice in CCA phase)
    /// @param amount The amount of the bid
    /// @param owner The owner of the bid
    /// @param prevTickPrice The price of the previous tick
    /// @param hookData Additional data to pass to the validation hook
    /// @return bidId The id of the bid
    function submitBid(uint256 maxPrice, uint128 amount, address owner, uint256 prevTickPrice, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);

    /// @notice Submit a new bid without specifying the previous tick price
    /// @param maxPrice The maximum price
    /// @param amount The amount of the bid
    /// @param owner The owner of the bid
    /// @param hookData Additional data to pass to the validation hook
    /// @return bidId The id of the bid
    function submitBid(uint256 maxPrice, uint128 amount, address owner, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);

    /// @notice Register a new checkpoint
    /// @return _checkpoint The checkpoint at the current block
    function checkpoint() external returns (Checkpoint memory _checkpoint);

    /// @notice Whether the auction has graduated
    /// @return bool True if the auction has graduated, false otherwise
    function isGraduated() external view returns (bool);

    /// @notice Get the currency required to raise for Auction to graduate
    /// @return The currency required to be raised
    function requiredCurrencyRaised() external view returns (uint256);

    /// @notice Get the currency raised at the last checkpointed block
    /// @return The currency raised
    function currencyRaised() external view returns (uint256);

    /// @notice Exit a bid (CCA phase bids only)
    /// @param bidId The id of the bid
    function exitBid(uint256 bidId) external;

    /// @notice Exit a partially filled bid
    /// @param bidId The id of the bid
    /// @param lastFullyFilledCheckpointBlock The last checkpoint where bid was fully filled
    /// @param outbidBlock The block where bid was outbid (0 if exiting at auction end)
    function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock) external;

    /// @notice Claim tokens after the auction's claim block
    /// @param bidId The id of the bid
    function claimTokens(uint256 bidId) external;

    /// @notice Claim tokens for multiple bids
    /// @param owner The owner of the bids
    /// @param bidIds The ids of the bids
    function claimTokensBatch(address owner, uint256[] calldata bidIds) external;

    /// @notice Withdraw all of the currency raised
    function sweepCurrency() external;

    /// @notice Sweep any leftover tokens to the tokens recipient
    function sweepUnsoldTokens() external;

    /// @notice The block at which the auction can be claimed
    function claimBlock() external view returns (uint64);

    /// @notice The address of the validation hook for the auction
    function validationHook() external view returns (IValidationHook);

    /// @notice The currency raised as of the last checkpoint (Q96*X7)
    function currencyRaisedQ96_X7() external view returns (ValueX7);

    /// @notice The sum of demand in ticks above the clearing price (CCA phase)
    function sumCurrencyDemandAboveClearingQ96() external view returns (uint256);

    /// @notice The total tokens sold as of the last checkpoint (Q96*X7)
    function totalClearedQ96_X7() external view returns (ValueX7);

    /// @notice The total tokens cleared as of the last checkpoint
    function totalCleared() external view returns (uint256);
}
