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
    error TokenRecipientIsZero();
    error FundsRecipientIsZero();
}
