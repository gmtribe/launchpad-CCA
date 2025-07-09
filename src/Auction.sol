// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AuctionParameters, AuctionStep} from './Base.sol';
import {IAuction} from './interfaces/IAuction.sol';
import {IValidationHook} from './interfaces/IValidationHook.sol';
import {IERC20} from './interfaces/external/IERC20.sol';

import {Bid, BidLib} from './libraries/BidLib.sol';
import {AuctionStepLib} from './libraries/AuctionStepLib.sol';

contract Auction is IAuction {
    using BidLib for Bid;
    using AuctionStepLib for bytes;

    struct Tick {
        uint128 id;
        uint128 prev;
        uint128 next;
        uint256 price;
        uint256 sumCurrencyDemand; // Sum of demand in the `currency` (exactIn)
        uint256 sumTokenDemand; // Sum of demand in the `token` (exactOut)
        Bid[] bids;
    }

    // Immutable args
    address public immutable currency;
    IERC20 public immutable token;
    uint256 public immutable totalSupply;
    address public immutable tokensRecipient;
    address public immutable fundsRecipient;
    uint256 public immutable startBlock;
    uint256 public immutable endBlock;
    uint256 public immutable claimBlock;
    uint256 public immutable tickSpacing;
    IValidationHook public immutable validationHook;
    uint256 public immutable floorPrice;

    // Storage
    bytes public auctionStepsData;
    AuctionStep public step;
    mapping(uint256 id => AuctionStep) public steps;
    uint256 public headId;
    uint256 public offset;

    uint256 public totalCleared;

    mapping(uint128 id => Tick) public ticks;
    uint128 public nextTickId;
    uint128 public tickUpperId;

    uint256 public clearingPrice;

    // Sum of exactIn demand if clearing price == tickUpper
    uint256 public sumCurrencyDemandAtTickUpper; 
    // Sum of exactOut demand >= tickUpper
    uint256 public sumTokenDemandAtTickUpper;

    constructor(AuctionParameters memory _parameters) {
        currency = _parameters.currency;
        token = IERC20(_parameters.token);
        totalSupply = _parameters.totalSupply;
        tokensRecipient = _parameters.tokensRecipient;
        fundsRecipient = _parameters.fundsRecipient;
        startBlock = _parameters.startBlock;
        endBlock = _parameters.endBlock;
        claimBlock = _parameters.claimBlock;
        tickSpacing = _parameters.tickSpacing;
        validationHook = IValidationHook(_parameters.validationHook);
        floorPrice = _parameters.floorPrice;
        auctionStepsData = _parameters.auctionStepsData;

        if (totalSupply == 0) revert TotalSupplyIsZero();
        if (floorPrice == 0) revert FloorPriceIsZero();
        if (tickSpacing == 0) revert TickSpacingIsZero();
        if (endBlock <= startBlock) revert EndBlockIsBeforeStartBlock();
        if (endBlock > type(uint256).max) revert EndBlockIsTooLarge();
        if (claimBlock < endBlock) revert ClaimBlockIsBeforeEndBlock();
        if (tokensRecipient == address(0)) revert TokenRecipientIsZero();
        if (fundsRecipient == address(0)) revert FundsRecipientIsZero();
    }

    function _aggregateDemandTickUpper() internal view returns (uint256 aggregatedDemand) {
        uint128 id = tickUpperId;
        Tick memory tick = ticks[id];

        // Resolve all exactIn demand at tickUpper price
        aggregatedDemand += tick.sumCurrencyDemand / tick.price;
        // Add all exactOut demand at tickUpper price
        aggregatedDemand += tick.sumTokenDemand;

        return aggregatedDemand;
    }

    /// @notice Record the current step
    function recordStep() public {
        if (block.number < step.endBlock) revert AuctionStepNotOver();

        uint256 _id = step.id;
        offset = _id * 8; // offset is the pointer to the next step in the auctionStepsData. Each step is a uint64 (8 bytes)
        uint256 _offset = offset;

        bytes memory _auctionStepsData = auctionStepsData;

        if (_offset >= _auctionStepsData.length) revert AuctionIsOver();

        (uint16 bps, uint48 blockDelta) = _auctionStepsData.get(_offset);

        _id++;
        uint256 _startBlock = block.number;
        uint256 _endBlock = _startBlock + blockDelta;
        step.id = _id;
        step.bps = bps;
        step.startBlock = _startBlock;
        step.endBlock = _endBlock;
        step.next = steps[headId].next;
        steps[headId].next = _id;
        headId = _id;

        emit AuctionStepRecorded(_id, _startBlock, _endBlock);
    }

    /// @notice Initialize a tick at with `price`
    function _initializeTickIfNeeded(uint128 prev, uint256 price) internal returns (uint128 id) {
        Tick memory tickLower = ticks[prev];
        uint128 next = tickLower.next;
        Tick memory tickUpper = ticks[next];

        if (tickUpper.price == price) return next;

        if (tickLower.price >= price || (tickUpper.price <= price && next != 0)) revert TickPriceNotIncreasing();

        nextTickId++;
        id = nextTickId;
        Tick storage tick = ticks[id];
        tick.id = id;
        tick.prev = prev;
        tick.next = next;
        tick.price = price;
        tick.sumCurrencyDemand = 0;
        tick.sumTokenDemand = 0;

        ticks[prev].next = id;
        if (next != 0) {
            ticks[next].prev = id;
        }

        emit TickInitialized(id, price);

        return id;
    }

    /// @notice Push a bid to a tick at `id`
    /// @dev requires the tick to be initialized
    function _updateTick(uint128 id, Bid calldata bid) internal {
        Tick storage tick = ticks[id];

        if (tick.price != bid.maxPrice) revert InvalidPrice();

        if (bid.exactIn) {
            tick.sumCurrencyDemand += bid.amount;
        } else {
            tick.sumTokenDemand += bid.amount;
        }

        tick.bids.push(bid); // use dynamic buffer here
    }

    /// @notice Update the clearing price
    function _updateClearingPrice() internal {
        uint256 resolvedSupply = AuctionStepLib.resolvedSupply(step, totalSupply, totalCleared);

        while(_aggregateDemandTickUpper() >= resolvedSupply) {
            Tick memory tickUpper = ticks[tickUpperId];
            // Subtract the demand at the old tickUpper as it has been outbid
            sumCurrencyDemandAtTickUpper -= tickUpper.sumCurrencyDemand;
            sumTokenDemandAtTickUpper -= tickUpper.sumTokenDemand;
            // New tickUpper is tickUpper.next
            tickUpperId = tickUpper.next;

            Tick memory tickUpperNext = ticks[tickUpperId];
            // Add the demand at the new tickUpper
            sumCurrencyDemandAtTickUpper += tickUpperNext.sumCurrencyDemand;
            sumTokenDemandAtTickUpper += tickUpperNext.sumTokenDemand;
        }

        // Find the clearing price between the tickLower and tickUpper
        uint256 _clearingPrice = sumCurrencyDemandAtTickUpper / (resolvedSupply - sumTokenDemandAtTickUpper);
        // Round clearingPrice down to the nearest tickSpacing
        _clearingPrice -= (_clearingPrice % tickSpacing);
        if (_clearingPrice < floorPrice) _clearingPrice = floorPrice;

        if (_clearingPrice > clearingPrice) {
            emit ClearingPriceUpdated(clearingPrice, _clearingPrice);
            clearingPrice = _clearingPrice;
        }
    }

    /// @notice Submit a new bid
    function submitBid(Bid calldata bid, uint128 prevHintId) external {
        bid.validate(floorPrice, tickSpacing);

        if (address(validationHook) != address(0)) {
            validationHook.validate(block.number);
        }

        if (block.number >= endBlock) recordStep();

        uint128 id = _initializeTickIfNeeded(prevHintId, bid.maxPrice);
        _updateTick(id, bid);

        // Only bids higher than the clearing price can change the clearing price
        if(bid.maxPrice > clearingPrice) {
            if (bid.exactIn) {
                sumCurrencyDemandAtTickUpper += bid.amount;
            } else {
                sumTokenDemandAtTickUpper += bid.amount;
            }
            _updateClearingPrice();
        }

        emit BidSubmitted(id, bid.maxPrice, bid.exactIn, bid.amount);
    }
}
