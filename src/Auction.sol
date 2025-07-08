// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AuctionParameters, AuctionStep} from './Base.sol';
import {IAuction} from './interfaces/IAuction.sol';
import {IValidationHook} from './interfaces/IValidationHook.sol';
import {IERC20} from './interfaces/external/IERC20.sol';

import {Bid, BidLib} from './libraries/BidLib.sol';

contract Auction is IAuction {
    using BidLib for Bid;

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
    uint256 public immutable tickSpacing;
    IValidationHook public immutable validationHook;
    uint256 public immutable floorPrice;

    // Storage
    bytes public auctionStepsData;
    AuctionStep public step;
    mapping(uint256 id => AuctionStep) public steps;
    uint256 public headId;
    uint256 public offset;

    uint256 public totalRemaining;

    mapping(uint128 id => Tick) public ticks;
    uint128 public clearingPriceId;
    uint128 public maxClearingPriceId;
    uint128 public nextTickId;

    constructor(AuctionParameters memory _parameters) {
        currency = _parameters.currency;
        token = IERC20(_parameters.token);
        totalSupply = _parameters.totalSupply;
        tokensRecipient = _parameters.tokensRecipient;
        fundsRecipient = _parameters.fundsRecipient;
        startBlock = _parameters.startBlock;
        endBlock = _parameters.endBlock;
        tickSpacing = _parameters.tickSpacing;
        validationHook = IValidationHook(_parameters.validationHook);
        floorPrice = _parameters.floorPrice;
        auctionStepsData = _parameters.auctionStepsData;

        totalRemaining = totalSupply;

        if (totalSupply == 0) revert TotalSupplyIsZero();
        if (floorPrice == 0) revert FloorPriceIsZero();
        if (tickSpacing == 0) revert TickSpacingIsZero();
        if (endBlock <= startBlock) revert EndBlockIsBeforeStartBlock();
        if (endBlock > type(uint256).max) revert EndBlockIsTooLarge();
        if (tokensRecipient == address(0)) revert TokenRecipientIsZero();
        if (fundsRecipient == address(0)) revert FundsRecipientIsZero();
    }

    /// @notice Record the current step
    function recordStep() public {
        if (block.number < step.endBlock) revert AuctionStepNotOver();

        // offset is the pointer to the next step in the auctionStepsData. Each step is a uint64
        // so we need to increment offset by 64
        offset += 64;
        uint256 _offset = offset;

        if (offset >= auctionStepsData.length) revert AuctionIsOver();

        uint16 bps;
        uint48 blockDelta;
        assembly {
            let packedValue := mload(add(auctionStepsData.offset, _offset))
            bps := shr(48, packedValue) // Extract top 16 bits
            blockDelta := and(packedValue, 0xFFFFFFFFFFFF) // Extract bottom 48 bits
        }

        step.id++;
        step.bps = bps;
        step.startBlock = block.number;
        step.endBlock = block.number + blockDelta;
        step.next = steps[headId].next;
        steps[headId].next = step.id;
        headId = step.id;
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

    function submitBid(Bid calldata bid, uint128 prevHintId) external {
        bid.validate(floorPrice, tickSpacing);

        if (address(validationHook) != address(0)) {
            validationHook.validate(block.number);
        }

        if (block.number >= endBlock) recordStep();

        uint128 id = _initializeTickIfNeeded(prevHintId, bid.maxPrice);
        _updateTick(id, bid);
    }
}
