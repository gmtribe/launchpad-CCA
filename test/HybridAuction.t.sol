// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridContinuousClearingAuction} from '../src/HybridContinuousClearingAuction.sol';
import {HybridAuctionParameters, IHybridContinuousClearingAuction} from '../src/interfaces/IHybridContinuousClearingAuction.sol';
import {IFixedPriceStorage} from '../src/interfaces/IFixedPriceStorage.sol';
import {ITickStorage} from '../src/interfaces/ITickStorage.sol';
import {ITokenCurrencyStorage} from '../src/interfaces/ITokenCurrencyStorage.sol';
import {Bid} from '../src/libraries/BidLib.sol';
import {Checkpoint} from '../src/libraries/CheckpointLib.sol';
import {FixedPoint96} from '../src/libraries/FixedPoint96.sol';
import {ValueX7, ValueX7Lib} from '../src/libraries/ValueX7Lib.sol';
import {ConstantsLib} from '../src/libraries/ConstantsLib.sol';
import {Currency} from '../src/libraries/CurrencyLibrary.sol';
import {HybridAuctionBaseTest} from './utils/HybridAuctionBaseTest.sol';
import {AuctionStepsBuilder} from './utils/AuctionStepsBuilder.sol';
import {console} from 'forge-std/console.sol';



contract HybridAuctionTest is HybridAuctionBaseTest {
    using AuctionStepsBuilder for bytes;
    using ValueX7Lib for *;

    function setUp() public {
        setUpAuction();
    }

    // ============================================
    // Constructor & Deployment Tests
    // ============================================

    function test_Auction_codeSize() public {
        vm.snapshotValue('Hybrid Auction bytecode size', address(auction).code.length);
    }

    function test_deployment_hybridMode_succeeds() public view {
        assertEq(auction.fixedPhaseTokenAllocation(), (TOTAL_SUPPLY * 30) / 100);
        assertEq(auction.fixedPriceBlockDuration(), 50);
        assertEq(auction.fixedPrice(), FLOOR_PRICE);
        assertTrue(auction.isFixedPricePhase());
        assertEq(auction.transitionBlock(), 0);
        assertEq(auction.ccaTotalSupply(), 0); // Not initialized yet
    }

    function test_deployment_pureCCA_succeeds() public {
        setUpTokens();
        
        bytes memory ccaSteps = AuctionStepsBuilder.init()
            .addStep(STANDARD_MPS_1_PERCENT, 50)
            .addStep(STANDARD_MPS_1_PERCENT, 50);
        
        HybridAuctionParameters memory pureCCAParams = HybridAuctionParameters({
            currency: ETH_SENTINEL,
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 110),
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: ccaSteps,
            fixedPhaseTokenAllocation: 0,
            fixedPriceBlockDuration: 0
        });
        
        HybridContinuousClearingAuction pureCCA = 
            new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, pureCCAParams);
        token.mint(address(pureCCA), TOTAL_SUPPLY);
        pureCCA.onTokensReceived();
        
        assertEq(pureCCA.fixedPhaseTokenAllocation(), 0);
        assertEq(pureCCA.fixedPriceBlockDuration(), 0);
        assertFalse(pureCCA.isFixedPricePhase());
        assertEq(pureCCA.transitionBlock(), pureCCAParams.startBlock);
        assertEq(pureCCA.ccaStartBlock(), pureCCAParams.startBlock);
        assertEq(pureCCA.ccaTotalSupply(), TOTAL_SUPPLY);
    }

    function test_deployment_invalidFloorPrice_reverts() public {
        params.floorPrice = 0;
        params.fixedPhaseTokenAllocation = 100e18;
        
        vm.expectRevert(ITickStorage.FloorPriceIsZero.selector);
        new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);
    }

    function test_deployment_allocationExceedsTotalSupply_reverts() public {
        params.fixedPhaseTokenAllocation = TOTAL_SUPPLY + 1;
        
        vm.expectRevert(IFixedPriceStorage.FixedPhaseAllocationExceedsTotalSupply.selector);
        new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);
    }

    function test_deployment_claimBlockBeforeEndBlock_reverts() public {
        params.claimBlock = params.endBlock - 1;
        
        vm.expectRevert(IHybridContinuousClearingAuction.ClaimBlockIsBeforeEndBlock.selector);
        new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);
    }

    // ============================================
    // Fixed Price Phase Tests
    // ============================================

    function test_submitBid_fixedPhase_fullFill_succeeds() public {
        uint256 currencyAmount = 100 ether;
        uint256 expectedTokens = (currencyAmount * FixedPoint96.Q96) / FLOOR_PRICE;
        
        vm.expectEmit(true, true, true, true);
        emit IHybridContinuousClearingAuction.FixedPriceOrderFilled(
            0, alice, uint128(expectedTokens), uint128(currencyAmount), 0
        );
        
        vm.deal(alice, currencyAmount);
        vm.prank(alice);
        uint256 bidId = auction.submitBid{value: currencyAmount}(
            FLOOR_PRICE,
            uint128(currencyAmount),
            alice,
            ""
        );
        
        Bid memory bid = auction.bids(bidId);
        assertEq(bid.tokensFilled, expectedTokens);
        assertEq(bid.exitedBlock, block.number);
        assertEq(auction.fixedPhaseSold(), uint128(expectedTokens));
    }

    function test_submitBid_fixedPhase_partialFill_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 firstOrderTokens = fixedPhaseAllocation - 100e18;
        uint256 firstOrderCurrency = (firstOrderTokens * FLOOR_PRICE) / FixedPoint96.Q96;
        vm.deal(alice, firstOrderCurrency);
        vm.prank(alice);
        auction.submitBid{value: firstOrderCurrency}(
            FLOOR_PRICE,
            uint128(firstOrderCurrency),
            alice,
            ""
        );
        
        uint256 availableTokens = 100e18;
        uint256 secondOrderCurrency = (availableTokens * 2 * FLOOR_PRICE) / FixedPoint96.Q96;
        uint256 expectedCurrencySpent = (availableTokens * FLOOR_PRICE) / FixedPoint96.Q96;
        uint256 expectedRefund = secondOrderCurrency - expectedCurrencySpent;
        
        uint256 bobBalanceBefore = bob.balance;
        vm.deal(bob, secondOrderCurrency);
        
        vm.expectEmit(true, true, true, true);
        emit IHybridContinuousClearingAuction.FixedPriceOrderFilled(
            1,
            bob,
            uint128(availableTokens),
            uint128(expectedCurrencySpent),
            uint128(expectedRefund)
        );
        
        vm.prank(bob);
        uint256 bidId = auction.submitBid{value: secondOrderCurrency}(
            FLOOR_PRICE,
            uint128(secondOrderCurrency),
            bob,
            ""
        );
        
        Bid memory bid = auction.bids(bidId);
        assertEq(bid.tokensFilled, availableTokens);
        assertEq(bob.balance, bobBalanceBefore + expectedRefund);
    }

    function test_submitBid_fixedPhase_belowFixedPrice_reverts() public {
        uint256 belowFixedPrice = FLOOR_PRICE - 1;
        
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(IHybridContinuousClearingAuction.BidBelowFixedPrice.selector);
        auction.submitBid{value: 1 ether}(
            belowFixedPrice,
            1 ether,
            alice,
            ""
        );
        vm.stopPrank();
    }

    function test_submitBid_fixedPhase_zeroAmount_reverts() public {
        vm.expectRevert(IHybridContinuousClearingAuction.BidAmountTooSmall.selector);
        auction.submitBid(FLOOR_PRICE, 0, alice, "");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_submitBid_fixedPhase_gas() public {
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        
        auction.submitBid{value: 1 ether}(FLOOR_PRICE, 1 ether, alice, "");
        vm.snapshotGasLastCall('fixedPriceOrder_first');
        
        auction.submitBid{value: 1 ether}(FLOOR_PRICE, 1 ether, alice, "");
        vm.snapshotGasLastCall('fixedPriceOrder_subsequent');
        
        vm.stopPrank();
    }

    // ============================================
    // Transition Tests
    // ============================================

    function test_transition_tokenAllocationMet_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        uint256 expectedRemainingTokens = TOTAL_SUPPLY - fixedPhaseAllocation;
        
        vm.expectEmit(true, true, true, true);
        emit IFixedPriceStorage.TransitionToCCAWithDetails(
            uint64(block.number),
            fixedPhaseAllocation,
            FLOOR_PRICE
        );
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        assertEq(auction.transitionBlock(), block.number);
        assertEq(auction.ccaTotalSupply(), expectedRemainingTokens);
        assertEq(auction.ccaStartBlock(), block.number);
    }

    function test_transition_blockDurationMet_succeeds() public {
        uint64 fixedPriceEndBlock = auction.fixedPriceEndBlock();
        vm.roll(fixedPriceEndBlock);
        
        vm.expectEmit(true, true, true, false);
        emit IFixedPriceStorage.TransitionToCCA(fixedPriceEndBlock);
        
        auction.checkpoint();
        
        assertFalse(auction.isFixedPricePhase());
        assertEq(auction.transitionBlock(), fixedPriceEndBlock);
    }

    function test_transition_tokenAllocationFirst_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.roll(block.number + 10); // Only 10 blocks, less than 50 block duration
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        assertTrue(auction.transitionBlock() < auction.fixedPriceEndBlock());
    }

    function test_transition_blockDurationFirst_succeeds() public {
        uint64 fixedPriceEndBlock = auction.fixedPriceEndBlock();
        vm.roll(fixedPriceEndBlock);
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 partialCurrency = ((uint256(fixedPhaseAllocation) / 10) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, partialCurrency);
        vm.prank(alice);
        auction.submitBid{value: partialCurrency}(FLOOR_PRICE, uint128(partialCurrency), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        assertTrue(auction.fixedPhaseSold() < fixedPhaseAllocation);
    }

    function test_transition_allTokensSold_reverts() public {
        // Create auction where all tokens go to fixed phase
        setUpTokens();
        
        bytes memory steps = AuctionStepsBuilder.init()
            .addStep(STANDARD_MPS_1_PERCENT, 100); // 100 blocks at 1% MPS each
        
        HybridAuctionParameters memory fullFixedParams = HybridAuctionParameters({
            currency: ETH_SENTINEL,
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 110),
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: steps,
            fixedPhaseTokenAllocation: TOTAL_SUPPLY,
            fixedPriceBlockDuration: 50
        });
        
        HybridContinuousClearingAuction fullFixed = 
            new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, fullFixedParams);
        token.mint(address(fullFixed), TOTAL_SUPPLY);
        fullFixed.onTokensReceived();
        
        uint256 currencyForAll = (uint256(TOTAL_SUPPLY) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        
        // Should revert when trying to transition with no tokens left
        vm.expectRevert(IHybridContinuousClearingAuction.NoTokensRemainingForCCA.selector);
        fullFixed.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
    }

    // ============================================
    // CCA Phase Tests (After Transition)
    // ============================================

    function test_submitBid_ccaPhase_afterTransition_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        
        vm.roll(block.number + 1);
        
        uint256 ccaPrice = FLOOR_PRICE + TICK_SPACING;
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bidId = auction.submitBid{value: 10 ether}(
            ccaPrice,
            10 ether,
            bob,
            ""
        );
        
        Bid memory bid = auction.bids(bidId);
        assertEq(bid.exitedBlock, 0); // Not yet exited
    }

    function test_submitBid_ccaPhase_updatesClearingPrice_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        vm.roll(block.number + 1);
        
        uint128 remainingSupply = auction.ccaTotalSupply();
        uint256 ccaPrice = FLOOR_PRICE + TICK_SPACING;
        uint128 inputAmount = inputAmountForTokens(remainingSupply, ccaPrice);
        
        vm.deal(bob, inputAmount);
        vm.prank(bob);
        auction.submitBid{value: inputAmount}(ccaPrice, inputAmount, bob, "");
        
        vm.roll(block.number + 1);
        auction.checkpoint();
        
        assertEq(auction.clearingPrice(), ccaPrice);
    }

    function test_submitBid_ccaPhase_belowClearingPrice_reverts() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        vm.roll(block.number + 1);
        
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(IHybridContinuousClearingAuction.BidMustBeAboveClearingPrice.selector);
        auction.submitBid{value: 10 ether}(FLOOR_PRICE, 10 ether, bob, "");
    }

    // ============================================
    // Mixed Phase Tests
    // ============================================

    function test_mixedPhase_fixedThenCCA_succeeds() public {
        uint256 fixedOrderCurrency = 50 ether;
        
        vm.deal(alice, fixedOrderCurrency);
        vm.prank(alice);
        uint256 bidId1 = auction.submitBid{value: fixedOrderCurrency}(
            FLOOR_PRICE,
            uint128(fixedOrderCurrency),
            alice,
            ""
        );
        
        assertTrue(auction.isFixedPricePhase());
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - auction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, remainingCurrency);
        vm.prank(alice);
        auction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        
        vm.roll(block.number + 1);
        
        uint256 ccaPrice = FLOOR_PRICE + TICK_SPACING;
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bidId2 = auction.submitBid{value: 10 ether}(ccaPrice, 10 ether, bob, "");
        
        Bid memory bid1 = auction.bids(bidId1);
        Bid memory bid2 = auction.bids(bidId2);
        
        assertGt(bid1.tokensFilled, 0);
        assertEq(bid1.exitedBlock, block.number - 1);
        assertEq(bid2.exitedBlock, 0);
    }

    function test_mixedPhase_totalClearedAccurate_succeeds() public {
        uint256 fixedOrderCurrency = 50 ether;
        uint256 expectedFixedTokens = (fixedOrderCurrency * FixedPoint96.Q96) / FLOOR_PRICE;
        
        vm.deal(alice, fixedOrderCurrency);
        vm.prank(alice);
        auction.submitBid{value: fixedOrderCurrency}(FLOOR_PRICE, uint128(fixedOrderCurrency), alice, "");
        
        uint256 totalClearedAfterFixed = auction.totalCleared();
        assertApproxEqAbs(totalClearedAfterFixed, expectedFixedTokens, 1e18);
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - auction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(bob, remainingCurrency);
        vm.prank(bob);
        auction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), bob, "");
        
        uint256 totalClearedAfterTransition = auction.totalCleared();
        assertApproxEqAbs(totalClearedAfterTransition, uint256(fixedPhaseAllocation), 1e18);
    }

    function test_mixedPhase_currencyRaisedAccurate_succeeds() public {
        uint256 fixedCurrency = 50 ether;
        
        vm.deal(alice, fixedCurrency);
        vm.prank(alice);
        auction.submitBid{value: fixedCurrency}(FLOOR_PRICE, uint128(fixedCurrency), alice, "");
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - auction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, remainingCurrency);
        vm.prank(alice);
        auction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        
        uint256 totalFixedCurrency = fixedCurrency + remainingCurrency;
        uint256 currencyRaised = auction.currencyRaised();
        
        assertApproxEqAbs(currencyRaised, totalFixedCurrency, 1e18);
    }

    // ============================================
    // Checkpoint Tests
    // ============================================

    // function test_checkpoint_duringFixedPhase_succeeds() public {
    //     vm.deal(alice, 1 ether);
    //     vm.prank(alice);
    //     auction.submitBid{value: 1 ether}(FLOOR_PRICE, 1 ether, alice, "");
        
    //     vm.roll(block.number + 1);
        
    //     Checkpoint memory checkpoint = auction.checkpoint();
    //     assertEq(checkpoint.clearingPrice, FLOOR_PRICE);
    // }

    function test_checkpoint_duringTransition_succeeds() public {
        uint64 fixedPriceEndBlock = auction.fixedPriceEndBlock();
        vm.roll(fixedPriceEndBlock);
        
        auction.checkpoint();
        
        assertFalse(auction.isFixedPricePhase());
        assertEq(auction.transitionBlock(), fixedPriceEndBlock);
    }

    function test_checkpoint_beforeTokensReceived_reverts() public {
        HybridContinuousClearingAuction newAuction = 
            new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);
        token.mint(address(newAuction), TOTAL_SUPPLY);
        
        vm.expectRevert(IHybridContinuousClearingAuction.TokensNotReceived.selector);
        newAuction.checkpoint();
    }

    // ============================================
    // Exit & Claim Tests
    // ============================================

    function test_exitAndClaim_fixedPriceOrder_succeeds() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 bidId = auction.submitBid{value: 10 ether}(FLOOR_PRICE, 10 ether, alice, "");
        
        vm.roll(auction.endBlock());
        auction.checkpoint();
        
        vm.roll(auction.claimBlock());
        
        Bid memory bid = auction.bids(bidId);
        uint256 tokensFilled = bid.tokensFilled;
        
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IHybridContinuousClearingAuction.TokensClaimed(bidId, alice, tokensFilled);
        auction.claimTokens(bidId);
        
        assertEq(token.balanceOf(alice), tokensFilled);
    }

    function test_exitAndClaim_ccaBid_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        vm.roll(block.number + 1);
        
        uint256 ccaPrice = FLOOR_PRICE + TICK_SPACING;
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bidId = auction.submitBid{value: 10 ether}(ccaPrice, 10 ether, bob, "");
        vm.roll(auction.endBlock());
        auction.checkpoint();
        
        vm.prank(bob);
        auction.exitBid(bidId);
        
        vm.roll(auction.claimBlock());
        Bid memory bid = auction.bids(bidId);
        uint256 tokensFilled = bid.tokensFilled;
        
        vm.prank(bob);
        auction.claimTokens(bidId);
        
        assertEq(token.balanceOf(bob), tokensFilled);
    }

    function test_claimTokensBatch_mixed_succeeds() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 bidId1 = auction.submitBid{value: 10 ether}(FLOOR_PRICE, 10 ether, alice, "");
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - auction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, remainingCurrency);
        vm.prank(alice);
        auction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        
        vm.roll(block.number + 1);
        uint256 ccaPrice = FLOOR_PRICE + TICK_SPACING;
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        uint256 bidId2 = auction.submitBid{value: 5 ether}(ccaPrice, 5 ether, alice, "");
        vm.roll(auction.endBlock());
        auction.checkpoint();
        
        vm.prank(alice);
        auction.exitBid(bidId2);
        
        vm.roll(auction.claimBlock());
        
        uint256[] memory bidIds = new uint256[](2);
        bidIds[0] = bidId1;
        bidIds[1] = bidId2;
        
        uint256 tokens1 = auction.bids(bidId1).tokensFilled;
        uint256 tokens2 = auction.bids(bidId2).tokensFilled;
        uint256 expectedTotal = tokens1 + tokens2;
        
        vm.prank(alice);
        auction.claimTokensBatch(alice, bidIds);
        
        assertEq(token.balanceOf(alice), expectedTotal);
    }

    // ============================================
    // Sweep Tests
    // ============================================

    function test_sweepCurrency_succeeds() public {
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        auction.submitBid{value: 100 ether}(FLOOR_PRICE, 100 ether, alice, "");
        
        // Trigger transition by checkpointing past fixed phase end
        vm.roll(auction.fixedPriceEndBlock() + 150);
        auction.checkpoint();
        
        // Now roll to after auction end
        vm.roll(auction.endBlock());
        auction.checkpoint();
        uint256 expectedCurrency = auction.currencyRaised();
        
        vm.expectEmit(true, true, true, true);
        emit ITokenCurrencyStorage.CurrencySwept(fundsRecipient, expectedCurrency);
        auction.sweepCurrency();
        
        assertEq(fundsRecipient.balance, expectedCurrency);
    }

    function test_sweepUnsoldTokens_afterFixedPhase_succeeds() public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 halfCurrency = ((uint256(fixedPhaseAllocation) / 2) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, halfCurrency);
        vm.prank(alice);
        auction.submitBid{value: halfCurrency}(FLOOR_PRICE, uint128(halfCurrency), alice, "");
        
        vm.roll(auction.fixedPriceEndBlock());
        auction.checkpoint();
        
        vm.roll(params.endBlock + 1);
        auction.checkpoint();
        
        uint256 unsoldExpected = TOTAL_SUPPLY - auction.fixedPhaseSold();
        
        auction.sweepUnsoldTokens();
        
        assertEq(token.balanceOf(tokensRecipient), unsoldExpected);
    }

    function test_sweepCurrency_alreadySwept_reverts() public {
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        auction.submitBid{value: 100 ether}(FLOOR_PRICE, 100 ether, alice, "");
        
        vm.roll(auction.endBlock());
        
        auction.sweepCurrency();
        
        vm.expectRevert(ITokenCurrencyStorage.CannotSweepCurrency.selector);
        auction.sweepCurrency();
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_edgeCase_maxUint128Order_doesNotOverflow() public {
        uint256 hugeCurrency = uint256(type(uint128).max);
        
        vm.deal(alice, hugeCurrency);
        vm.prank(alice);
        auction.submitBid{value: hugeCurrency}(
            FLOOR_PRICE,
            type(uint128).max,
            alice,
            ""
        );
        
        // Should either fill or partial fill without reverting
    }

    // ============================================
    // Getters Tests
    // ============================================

    function test_constructor_immutable_getters() public view {
        assertEq(Currency.unwrap(auction.currency()), ETH_SENTINEL);
        assertEq(address(auction.token()), address(token));
        assertEq(auction.totalSupply(), TOTAL_SUPPLY);
        assertEq(auction.tokensRecipient(), tokensRecipient);
        assertEq(auction.fundsRecipient(), fundsRecipient);
        assertEq(auction.tickSpacing(), TICK_SPACING);
        assertEq(address(auction.validationHook()), address(0));
        assertEq(auction.floorPrice(), FLOOR_PRICE);
        assertEq(auction.fixedPrice(), FLOOR_PRICE);
    }
}
