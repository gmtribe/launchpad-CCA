// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Auction, AuctionParameters} from '../src/Auction.sol';
import {IAuction} from '../src/interfaces/IAuction.sol';
import {Test} from 'forge-std/Test.sol';

contract AuctionTest is Test {
    Auction auction;

    function setUp() public {
        AuctionParameters memory params = AuctionParameters({
            currency: address(0),
            token: address(0),
            totalSupply: 1000,
            floorPrice: 100,
            tickSpacing: 10,
            validationHook: address(0),
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: 0,
            endBlock: 0,
            auctionStepsData: new bytes(0)
        });
        auction = new Auction(params);
    }
}
