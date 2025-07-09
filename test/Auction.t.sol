// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Auction, AuctionParameters} from '../src/Auction.sol';
import {IAuction} from '../src/interfaces/IAuction.sol';
import {Test} from 'forge-std/Test.sol';
import {TokenHandler} from './utils/TokenHandler.sol';
import {AuctionParamsBuilder} from './utils/AuctionParamsBuilder.sol';
import {AuctionStepsBuilder} from './utils/AuctionStepsBuilder.sol';
import {IAuction} from '../src/interfaces/IAuction.sol';

contract AuctionTest is TokenHandler, Test {
    using AuctionParamsBuilder for AuctionParameters;
    using AuctionStepsBuilder for bytes;
    
    Auction auction;

    uint256 public constant AUCTION_DURATION = 100;
    uint256 public constant TICK_SPACING = 1e18;
    uint256 public constant FLOOR_PRICE = 1e18;
    uint256 public constant TOTAL_SUPPLY = 1000e18;

    address public tokensRecipient;
    address public fundsRecipient;

    function setUp() public {
        setUpTokens();

        tokensRecipient = makeAddr("tokensRecipient");
        fundsRecipient = makeAddr("fundsRecipient");

        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(5000, 50).addStep(5000, 50);
        AuctionParameters memory params = AuctionParamsBuilder.init()
            .withCurrency(address(currency))
            .withToken(address(token))
            .withTotalSupply(TOTAL_SUPPLY)
            .withFloorPrice(FLOOR_PRICE)
            .withTickSpacing(TICK_SPACING)
            .withValidationHook(address(0))
            .withTokensRecipient(tokensRecipient)
            .withFundsRecipient(fundsRecipient)
            .withStartBlock(block.number)
            .withEndBlock(block.number + AUCTION_DURATION)
            .withClaimBlock(block.number + AUCTION_DURATION)
            .withAuctionStepsData(auctionStepsData);

        auction = new Auction(params);
    }

    function test_recordStep_succeedsToBeginAuction() public {
        vm.expectEmit(true, true, true, true);
        emit IAuction.AuctionStepRecorded(1, block.number, block.number + 50);
        auction.recordStep();
    }
}
