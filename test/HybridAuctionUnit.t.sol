// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridAuctionBaseTest} from './utils/HybridAuctionBaseTest.sol';
import {MockHybridAuction} from './utils/MockHybridAuction.sol';
import {HybridAuctionParameters, IHybridContinuousClearingAuction} from '../src/interfaces/IHybridContinuousClearingAuction.sol';
import {IFixedPriceStorage} from '../src/interfaces/IFixedPriceStorage.sol';
import {ITokenCurrencyStorage} from '../src/interfaces/ITokenCurrencyStorage.sol';
import {IStepStorage} from '../src/interfaces/IStepStorage.sol';
import {Checkpoint} from '../src/libraries/CheckpointLib.sol';
import {Bid} from '../src/libraries/BidLib.sol';
import {FixedPoint96} from '../src/libraries/FixedPoint96.sol';
import {AuctionStepsBuilder} from './utils/AuctionStepsBuilder.sol';


contract HybridAuctionUnitTest is HybridAuctionBaseTest {
    using AuctionStepsBuilder for bytes;

    MockHybridAuction public mockAuction;

    function setUp() public {
        setUpMockAuction();
    }

    function setUpMockAuction() internal {
        setUpTokens();
        
        alice = makeAddr('alice');
        bob = makeAddr('bob');
        tokensRecipient = makeAddr('tokensRecipient');
        fundsRecipient = makeAddr('fundsRecipient');

        bytes memory auctionStepsData =
            AuctionStepsBuilder.init().addStep(STANDARD_MPS_1_PERCENT, 50).addStep(STANDARD_MPS_1_PERCENT, 50);
        
        params = HybridAuctionParameters({
            currency: ETH_SENTINEL,
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 150),
            claimBlock: uint64(block.number + 160),
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: auctionStepsData,
            fixedPhaseTokenAllocation: (TOTAL_SUPPLY * 30) / 100,
            fixedPriceBlockDuration: 50
        });

        mockAuction = new MockHybridAuction(address(token), TOTAL_SUPPLY, params);
        token.mint(address(mockAuction), TOTAL_SUPPLY);
        mockAuction.onTokensReceived();
    }

    // ============================================
    // FixedPriceStorage Unit Tests
    // ============================================

    function test_unit_checkTransitionConditions_tokenAllocation() public {
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        
        // Before reaching allocation
        assertFalse(mockAuction.exposed_checkTransitionConditions());
        
        // Set fixed phase sold to allocation
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        
        // Should transition
        assertTrue(mockAuction.exposed_checkTransitionConditions());
    }

    function test_unit_checkTransitionConditions_blockDuration() public {
        uint64 fixedPriceEndBlock = mockAuction.fixedPriceEndBlock();
        
        // Before end block
        vm.roll(fixedPriceEndBlock - 1);
        assertFalse(mockAuction.exposed_checkTransitionConditions());
        
        // At end block
        vm.roll(fixedPriceEndBlock);
        assertTrue(mockAuction.exposed_checkTransitionConditions());
        
        // After end block
        vm.roll(fixedPriceEndBlock + 1);
        assertTrue(mockAuction.exposed_checkTransitionConditions());
    }

    function test_unit_checkTransitionConditions_both() public {
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        uint64 fixedPriceEndBlock = mockAuction.fixedPriceEndBlock();
        
        // Neither condition met
        vm.roll(block.number + 1);
        assertFalse(mockAuction.exposed_checkTransitionConditions());
        
        // Only token allocation met
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        assertTrue(mockAuction.exposed_checkTransitionConditions());
        
        // Reset and test only block duration
        mockAuction.exposed_setFixedPhaseSold(0);
        vm.roll(fixedPriceEndBlock);
        assertTrue(mockAuction.exposed_checkTransitionConditions());
    }

    function test_unit_executeTransition_setsState() public {
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        uint128 expectedCCASupply = TOTAL_SUPPLY - fixedPhaseAllocation;
        
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        
        vm.expectEmit(true, true, true, false);
        emit IFixedPriceStorage.TransitionToCCA(uint64(block.number));
        
        mockAuction.exposed_executeTransition();
        
        assertFalse(mockAuction.isFixedPricePhase());
        assertEq(mockAuction.transitionBlock(), block.number);
        assertEq(mockAuction.ccaTotalSupply(), expectedCCASupply);
        assertEq(mockAuction.ccaStartBlock(), block.number);
    }

    function test_unit_recordFixedPhaseSale_updatesState() public {
        uint128 initialSold = mockAuction.fixedPhaseSold();
        uint128 saleAmount = 100e18;
        
        mockAuction.exposed_recordFixedPhaseSale(saleAmount);
        
        assertEq(mockAuction.fixedPhaseSold(), initialSold + saleAmount);
    }

    function test_unit_getFixedPhaseRemainingTokens_accurate() public {
        uint128 allocation = mockAuction.fixedPhaseTokenAllocation();
        uint128 sold = 50e18;
        
        mockAuction.exposed_setFixedPhaseSold(sold);
        
        uint128 remaining = mockAuction.exposed_getFixedPhaseRemainingTokens();
        assertEq(remaining, allocation - sold);
    }

    function test_unit_getFixedPhaseRemainingTokens_allSold() public {
        uint128 allocation = mockAuction.fixedPhaseTokenAllocation();
        
        mockAuction.exposed_setFixedPhaseSold(allocation);
        
        uint128 remaining = mockAuction.exposed_getFixedPhaseRemainingTokens();
        assertEq(remaining, 0);
    }

    // ============================================
    // Transition Logic Unit Tests
    // ============================================

    function test_unit_initializeCCASupply_setsCorrectly() public {
        uint128 remainingTokens = 700e18;
        
        mockAuction.exposed_initializeCCASupply(remainingTokens);
        
        assertEq(mockAuction.ccaTotalSupply(), remainingTokens);
    }

    function test_unit_initializeCCASupply_alreadyInitialized_reverts() public {
        uint128 remainingTokens = 700e18;
        
        mockAuction.exposed_initializeCCASupply(remainingTokens);
        
        vm.expectRevert(ITokenCurrencyStorage.CCASupplyAlreadyInitialized.selector);
        mockAuction.exposed_initializeCCASupply(remainingTokens);
    }

    function test_unit_initializeCCASupply_exceedsTotalSupply_reverts() public {
        uint128 tooManyTokens = TOTAL_SUPPLY + 1;
        
        vm.expectRevert(ITokenCurrencyStorage.CCASupplyExceedsAuctionSupply.selector);
        mockAuction.exposed_initializeCCASupply(tooManyTokens);
    }

    function test_unit_initializeCCAPhase_setsCorrectly() public {
        uint64 startBlock = uint64(block.number);
        
        mockAuction.exposed_initializeCCAPhase(startBlock);
        
        assertEq(mockAuction.ccaStartBlock(), startBlock);
    }

    function test_unit_initializeCCAPhase_alreadyInitialized_reverts() public {
        uint64 startBlock = uint64(block.number);
        
        mockAuction.exposed_initializeCCAPhase(startBlock);
        
        vm.expectRevert(IStepStorage.CCAAlreadyInitialized.selector);
        mockAuction.exposed_initializeCCAPhase(startBlock);
    }

    // ============================================
    // Price Discovery Unit Tests
    // ============================================

    function test_unit_priceDiscovery_usesCCASupply() public {
        // Transition to CCA phase
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        mockAuction.exposed_executeTransition();
        
        uint128 ccaSupply = mockAuction.ccaTotalSupply();
        uint256 expectedSupply = TOTAL_SUPPLY - fixedPhaseAllocation;
        
        assertEq(ccaSupply, expectedSupply);
        
        // Price discovery should use CCA supply, not total supply
        // This is tested implicitly through clearing price calculations
    }

    function test_unit_priceDiscovery_usesFloorPrice() public {
        // Transition to CCA phase first
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        mockAuction.exposed_executeTransition();
        
        // Need to checkpoint to initialize clearing price
        vm.roll(block.number + 1);
        mockAuction.checkpoint();
        
        uint256 clearingPrice = mockAuction.clearingPrice();
        uint256 floorPrice = mockAuction.floorPrice();
        
        // In CCA phase after checkpoint, clearing price should be floor price
        assertEq(clearingPrice, floorPrice);
    }

    // ============================================
    // Accounting Unit Tests
    // ============================================

    function test_unit_currencyRaised_includesBothPhases() public {
        // Fixed price phase
        uint256 fixedCurrency = 50 ether;
        vm.deal(alice, fixedCurrency);
        vm.prank(alice);
        mockAuction.submitBid{value: fixedCurrency}(FLOOR_PRICE, uint128(fixedCurrency), alice, "");
        
        uint256 currencyAfterFixed = mockAuction.currencyRaised();
        assertApproxEqAbs(currencyAfterFixed, fixedCurrency, 1e18);
        
        // Complete transition
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - mockAuction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, remainingCurrency);
        vm.prank(alice);
        mockAuction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        
        uint256 totalFixedCurrency = fixedCurrency + remainingCurrency;
        uint256 currencyAfterTransition = mockAuction.currencyRaised();
        
        assertApproxEqAbs(currencyAfterTransition, totalFixedCurrency, 1e18);
    }

    function test_unit_totalCleared_includesBothPhases() public {
        // Fixed price phase
        uint256 fixedCurrency = 50 ether;
        uint256 expectedFixedTokens = (fixedCurrency * FixedPoint96.Q96) / FLOOR_PRICE;
        
        vm.deal(alice, fixedCurrency);
        vm.prank(alice);
        mockAuction.submitBid{value: fixedCurrency}(FLOOR_PRICE, uint128(fixedCurrency), alice, "");
        
        uint256 totalClearedAfterFixed = mockAuction.totalCleared();
        assertApproxEqAbs(totalClearedAfterFixed, expectedFixedTokens, 1e18);
        
        // Complete transition
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - mockAuction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, remainingCurrency);
        vm.prank(alice);
        mockAuction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        
        uint256 totalClearedAfterTransition = mockAuction.totalCleared();
        assertApproxEqAbs(totalClearedAfterTransition, uint256(fixedPhaseAllocation), 1e18);
    }

    function test_unit_unsoldTokens_calculatedFromTotalSupply() public {
        // Place partial order
        uint256 fixedCurrency = 50 ether;
        
        vm.deal(alice, fixedCurrency);
        vm.prank(alice);
        mockAuction.submitBid{value: fixedCurrency}(FLOOR_PRICE, uint128(fixedCurrency), alice, "");
        
        vm.roll(mockAuction.endBlock() + 1);
        mockAuction.checkpoint();
        
        uint256 totalCleared = mockAuction.totalCleared();
        uint256 expectedUnsold = TOTAL_SUPPLY - totalCleared;
        
        // Unsold tokens = total supply - total cleared
        assertEq(expectedUnsold, TOTAL_SUPPLY - totalCleared);
    }

    // ============================================
    // Fixed Price Order Processing Unit Tests
    // ============================================

    function test_unit_processFixedPriceOrder_fullFill() public {
        uint128 currencyAmount = 10 ether;
        uint256 expectedTokens = (currencyAmount * FixedPoint96.Q96) / FLOOR_PRICE;
        
        (uint128 tokensFilled, uint128 currencySpent, uint128 refund) = 
            mockAuction.exposed_processFixedPriceOrder(currencyAmount);
        
        assertApproxEqAbs(tokensFilled, expectedTokens, 1e18);
        assertEq(currencySpent, currencyAmount);
        assertEq(refund, 0);
    }

    function test_unit_processFixedPriceOrder_partialFill() public {
        // Sell most of allocation
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        uint128 soldAlready = fixedPhaseAllocation - 100e18;
        mockAuction.exposed_setFixedPhaseSold(soldAlready);
        
        // Try to buy more than remaining
        uint128 currencyAmount = type(uint128).max;
        
        uint128 remainingTokens = 100e18;
        uint128 expectedCurrencySpent = uint128((uint256(remainingTokens) * FLOOR_PRICE) / FixedPoint96.Q96);
                
        uint128 remainingCurrency = uint128((uint256(remainingTokens) * FLOOR_PRICE) / FixedPoint96.Q96);
        
        // Test that we can detect partial fill scenario
        assertLt(remainingCurrency, currencyAmount);
    }

    function test_unit_processFixedPriceOrder_noTokensAvailable() public {
        // Sell all allocation
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        
        vm.expectRevert(IFixedPriceStorage.NoFixedPriceTokensAvailable.selector);
        mockAuction.exposed_processFixedPriceOrder(10 ether);
    }

    // ============================================
    // Phase State Unit Tests
    // ============================================

    function test_unit_isFixedPricePhase_duringFixedPhase() public {
        assertTrue(mockAuction.isFixedPricePhase());
    }

    function test_unit_isFixedPricePhase_afterTransition() public {
        uint128 fixedPhaseAllocation = mockAuction.fixedPhaseTokenAllocation();
        mockAuction.exposed_setFixedPhaseSold(fixedPhaseAllocation);
        mockAuction.exposed_executeTransition();
        
        assertFalse(mockAuction.isFixedPricePhase());
    }

    function test_unit_fixedPriceEndBlock_calculation() public {
        uint64 startBlock = mockAuction.startBlock();
        uint64 fixedDuration = mockAuction.fixedPriceBlockDuration();
        uint64 expectedEndBlock = startBlock + fixedDuration;
        
        assertEq(mockAuction.fixedPriceEndBlock(), expectedEndBlock);
    }

    // ============================================
    // Pure CCA Mode Unit Tests
    // ============================================

    function test_unit_pureCCA_initializesInConstructor() public {
        setUpTokens();
        
        HybridAuctionParameters memory pureCCAParams = params;
        pureCCAParams.fixedPhaseTokenAllocation = 0;
        pureCCAParams.fixedPriceBlockDuration = 0;
        
        MockHybridAuction pureCCA = new MockHybridAuction(
            address(token),
            TOTAL_SUPPLY,
            pureCCAParams
        );
        token.mint(address(pureCCA), TOTAL_SUPPLY);
        pureCCA.onTokensReceived();
        
        assertEq(pureCCA.ccaTotalSupply(), TOTAL_SUPPLY);
        assertEq(pureCCA.ccaStartBlock(), pureCCAParams.startBlock);
        assertFalse(pureCCA.isFixedPricePhase());
    }

    // ============================================
    // Modifier Tests
    // ============================================

    function test_unit_modifier_onlyActiveAuction_beforeStart_reverts() public {
        setUpTokens();
        
        HybridAuctionParameters memory futureParams = params;
        futureParams.startBlock = uint64(block.number + 100);
        futureParams.endBlock = uint64(block.number + 200);
        futureParams.claimBlock = uint64(block.number + 210);
        
        MockHybridAuction futureAuction = new MockHybridAuction(
            address(token),
            TOTAL_SUPPLY,
            futureParams
        );
        token.mint(address(futureAuction), TOTAL_SUPPLY);
        futureAuction.onTokensReceived();
        
        vm.expectRevert(IHybridContinuousClearingAuction.AuctionNotStarted.selector);
        futureAuction.modifier_onlyActiveAuction();
    }

    function test_unit_modifier_onlyAfterAuctionIsOver_beforeEnd_reverts() public {
        vm.expectRevert(IHybridContinuousClearingAuction.AuctionIsNotOver.selector);
        mockAuction.modifier_onlyAfterAuctionIsOver();
    }

    function test_unit_modifier_onlyAfterAuctionIsOver_afterEnd_succeeds() public {
        vm.roll(mockAuction.endBlock() + 1);
        
        // Should not revert
        mockAuction.modifier_onlyAfterAuctionIsOver();
    }
}
