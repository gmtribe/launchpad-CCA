// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAuction {
    error AuctionStepNotOver();
    error AuctionIsOver();
    error TickPriceNotIncreasing();
    error InvalidPrice();
    error TotalSupplyIsZero();
    error FloorPriceIsZero();
    error TickSpacingIsZero();
    error EndBlockIsBeforeStartBlock();
    error EndBlockIsTooLarge();
    error ClaimBlockIsBeforeEndBlock();
    error TokenRecipientIsZero();
    error FundsRecipientIsZero();

    event AuctionStepRecorded(uint256 indexed id, uint256 startBlock, uint256 endBlock);
    event BidSubmitted(uint128 indexed id, uint256 price, bool exactIn, uint256 amount);
    event ClearingPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TickInitialized(uint128 id, uint256 price);
}
