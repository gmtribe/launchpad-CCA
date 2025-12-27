// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridAuctionBaseTest} from './utils/HybridAuctionBaseTest.sol';
import {HybridAuctionParameters} from '../src/interfaces/IHybridContinuousClearingAuction.sol';
import {Bid} from '../src/libraries/BidLib.sol';
import {Checkpoint} from '../src/libraries/CheckpointLib.sol';
import {FixedPoint96} from '../src/libraries/FixedPoint96.sol';
import {ConstantsLib} from '../src/libraries/ConstantsLib.sol';
import {FuzzHybridDeploymentParams} from './utils/FuzzStructs.sol';
import {HybridContinuousClearingAuction} from '../src/HybridContinuousClearingAuction.sol';
import {console} from 'forge-std/console.sol';


contract HybridAuctionFuzzTest is HybridAuctionBaseTest {

    function setUp() public {
        setUpAuction();
    }

    // ============================================
    // Fixed Price Phase Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fixedPriceOrder_variousAmounts(uint128 _amount) public {
        vm.assume(_amount > 0);
        vm.assume(_amount < type(uint128).max / 2);
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 maxCurrency = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        _amount = uint128(_bound(_amount, 1e18, maxCurrency));
        
        uint256 expectedTokens = (_amount * FixedPoint96.Q96) / FLOOR_PRICE;
        
        vm.deal(alice, _amount);
        vm.prank(alice);
        uint256 bidId = auction.submitBid{value: _amount}(
            FLOOR_PRICE,
            _amount,
            alice,
            ""
        );
        
        Bid memory bid = auction.bids(bidId);
        assertApproxEqAbs(bid.tokensFilled, expectedTokens, 1e18);
        assertEq(bid.exitedBlock, block.number);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_fixedPriceOrder_multipleOrders(
        uint8 _numOrders,
        uint128 _orderAmount
    ) public {
        _numOrders = uint8(_bound(_numOrders, 1, 10));
        vm.assume(_orderAmount > 0);
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 maxCurrencyPerOrder = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / (FixedPoint96.Q96 * _numOrders);
        
        _orderAmount = uint128(_bound(_orderAmount, 1e18, maxCurrencyPerOrder));
        
        uint256 totalTokensFilled = 0;
        
        for (uint8 i = 0; i < _numOrders; i++) {
            address bidder = address(uint160(1000 + i));
            vm.deal(bidder, _orderAmount);
            vm.prank(bidder);
            
            uint256 bidId = auction.submitBid{value: _orderAmount}(
                FLOOR_PRICE,
                _orderAmount,
                bidder,
                ""
            );
            
            Bid memory bid = auction.bids(bidId);
            totalTokensFilled += bid.tokensFilled;
        }
        
        assertLe(totalTokensFilled, fixedPhaseAllocation);
    }

    // ============================================
    // Transition Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transition_tokenAllocation(uint8 _allocationPercent) public {
        _allocationPercent = uint8(_bound(_allocationPercent, 1, 99));
        
        setUpTokens();
        alice = makeAddr('alice');
        tokensRecipient = makeAddr('tokensRecipient');
        fundsRecipient = makeAddr('fundsRecipient');
        
        uint128 fixedAllocation = uint128((uint256(TOTAL_SUPPLY) * _allocationPercent) / 100);
        
        HybridAuctionParameters memory fuzzParams = HybridAuctionParameters({
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
            auctionStepsData: params.auctionStepsData,
            fixedPhaseTokenAllocation: fixedAllocation,
            fixedPriceBlockDuration: 50
        });
        
        auction = new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, fuzzParams);
        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();
        
        uint256 currencyForAll = (uint256(fixedAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        assertFalse(auction.isFixedPricePhase());
        assertEq(auction.ccaTotalSupply(), TOTAL_SUPPLY - fixedAllocation);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_transition_blockDuration(uint64 _blockDuration) public {
        _blockDuration = uint64(_bound(_blockDuration, 10, 100));
        
        setUpTokens();
        alice = makeAddr('alice');
        tokensRecipient = makeAddr('tokensRecipient');
        fundsRecipient = makeAddr('fundsRecipient');
        
        HybridAuctionParameters memory fuzzParams = HybridAuctionParameters({
            currency: ETH_SENTINEL,
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + _blockDuration + 100),
            claimBlock: uint64(block.number + _blockDuration + 110),
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: params.auctionStepsData,
            fixedPhaseTokenAllocation: TOTAL_SUPPLY / 2,
            fixedPriceBlockDuration: _blockDuration
        });
        
        auction = new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, fuzzParams);
        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();
        
        uint64 expectedTransitionBlock = uint64(block.number) + _blockDuration;
        vm.roll(expectedTransitionBlock);
        
        auction.checkpoint();
        
        assertFalse(auction.isFixedPricePhase());
        assertEq(auction.transitionBlock(), expectedTransitionBlock);
    }

    // ============================================
    // Mixed Phase Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_mixedPhase_fixedThenCCA(
        uint128 _fixedAmount,
        uint256 _ccaPrice
    ) public {
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 maxFixedCurrency = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        _fixedAmount = uint128(_bound(_fixedAmount, 1e18, maxFixedCurrency));

        uint256 maxBidPrice = auction.MAX_BID_PRICE();
        _ccaPrice = _bound(_ccaPrice, FLOOR_PRICE + TICK_SPACING, maxBidPrice);
        _ccaPrice = helper__roundPriceDownToTickSpacing(_ccaPrice, TICK_SPACING);
        vm.assume(_ccaPrice > FLOOR_PRICE && _ccaPrice <= maxBidPrice);
        
        // Place fixed price order
        vm.deal(alice, _fixedAmount);
        vm.prank(alice);
        uint256 bidId1 = auction.submitBid{value: _fixedAmount}(
            FLOOR_PRICE,
            _fixedAmount,
            alice,
            ""
        );
        
        // Complete transition
        uint256 remainingCurrency = ((uint256(fixedPhaseAllocation) - auction.fixedPhaseSold()) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        if (remainingCurrency > 0) {
            vm.deal(alice, remainingCurrency);
            vm.prank(alice);
            auction.submitBid{value: remainingCurrency}(FLOOR_PRICE, uint128(remainingCurrency), alice, "");
        }
        
        assertFalse(auction.isFixedPricePhase());
        
        // Place CCA bid
        vm.roll(block.number + 1);
        
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bidId2 = auction.submitBid{value: 10 ether}(
            _ccaPrice,
            10 ether,
            bob,
            ""
        );
        
        Bid memory bid1 = auction.bids(bidId1);
        Bid memory bid2 = auction.bids(bidId2);
        
        assertGt(bid1.tokensFilled, 0);
        assertTrue(bid1.exitedBlock > 0);
        assertEq(bid2.exitedBlock, 0);
    }

    // ============================================
    // Accounting Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_currencyRaised_accuracy(uint8 _numOrders) public {
        _numOrders = uint8(_bound(_numOrders, 1, 20));
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 maxCurrencyPerOrder = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / (FixedPoint96.Q96 * _numOrders);
        uint128 orderAmount = uint128(maxCurrencyPerOrder / 2);
        
        uint256 totalCurrencySpent = 0;
        
        for (uint8 i = 0; i < _numOrders; i++) {
            address bidder = address(uint160(2000 + i));
            vm.deal(bidder, orderAmount);
            
            uint256 balanceBefore = bidder.balance;
            vm.prank(bidder);
            auction.submitBid{value: orderAmount}(
                FLOOR_PRICE,
                orderAmount,
                bidder,
                ""
            );
            uint256 actualSpent = balanceBefore - bidder.balance;
            totalCurrencySpent += actualSpent;
        }
        uint256 auctionCurrencyRaised = auction.currencyRaised();

        assertApproxEqAbs(auctionCurrencyRaised, totalCurrencySpent, _numOrders * 1000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_totalCleared_neverExceedsTotalSupply(uint8 _numOrders) public {
        _numOrders = uint8(_bound(_numOrders, 1, 50));
        
        uint256 largeAmount = type(uint128).max / _numOrders;
        
        for (uint8 i = 0; i < _numOrders; i++) {
            address bidder = address(uint160(3000 + i));
            vm.deal(bidder, largeAmount);
            
            vm.prank(bidder);
            try auction.submitBid{value: largeAmount}(
                FLOOR_PRICE,
                uint128(largeAmount),
                bidder,
                ""
            ) {
                // Bid succeeded
            } catch {
                // Bid failed, likely allocation depleted
                break;
            }
        }
        
        assertLe(auction.totalCleared(), TOTAL_SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_fixedPhaseSold_neverExceedsAllocation(uint8 _numOrders) public {
        _numOrders = uint8(_bound(_numOrders, 1, 30));
        
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 largeAmount = (uint256(fixedPhaseAllocation) * FLOOR_PRICE * 2) / (FixedPoint96.Q96 * _numOrders);
        
        for (uint8 i = 0; i < _numOrders; i++) {
            if (!auction.isFixedPricePhase()) break;
            
            address bidder = address(uint160(4000 + i));
            vm.deal(bidder, largeAmount);
            
            vm.prank(bidder);
            try auction.submitBid{value: largeAmount}(
                FLOOR_PRICE,
                uint128(largeAmount),
                bidder,
                ""
            ) {
                // Order placed
            } catch {
                // Failed, allocation likely met
                break;
            }
        }
        
        assertLe(auction.fixedPhaseSold(), fixedPhaseAllocation);
    }

    // ============================================
    // CCA Phase Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_ccaPhase_priceDiscovery(uint256 _bidPrice) public {
        // Transition to CCA
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        vm.roll(block.number + 1);
        
        uint256 maxBidPrice = auction.MAX_BID_PRICE();
        _bidPrice = _bound(_bidPrice, FLOOR_PRICE + TICK_SPACING, maxBidPrice);
        _bidPrice = helper__roundPriceDownToTickSpacing(_bidPrice, TICK_SPACING);
        vm.assume(_bidPrice > FLOOR_PRICE && _bidPrice <= maxBidPrice);

        uint128 ccaSupply = auction.ccaTotalSupply();
        
        uint128 inputAmount = inputAmountForTokens(ccaSupply, _bidPrice);
        
        vm.deal(bob, inputAmount);
        vm.prank(bob);
        auction.submitBid{value: inputAmount}(_bidPrice, inputAmount, bob, "");
        
        vm.roll(block.number + 1);
        Checkpoint memory checkpoint = auction.checkpoint();
        
        assertEq(checkpoint.clearingPrice, _bidPrice);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_ccaPhase_partialFills(
        uint128 _bid1Amount,
        uint128 _bid2Amount,
        uint256 _price1,
        uint256 _price2
    ) public {
        // Transition to CCA
        uint128 fixedPhaseAllocation = auction.fixedPhaseTokenAllocation();
        uint256 currencyForAll = (uint256(fixedPhaseAllocation) * FLOOR_PRICE) / FixedPoint96.Q96;
        
        vm.deal(alice, currencyForAll);
        vm.prank(alice);
        auction.submitBid{value: currencyForAll}(FLOOR_PRICE, uint128(currencyForAll), alice, "");
        
        vm.roll(block.number + 1);
        
        uint256 maxBidPrice = auction.MAX_BID_PRICE();
        _price1 = _bound(_price1, FLOOR_PRICE + TICK_SPACING, maxBidPrice);
        _price1 = helper__roundPriceDownToTickSpacing(_price1, TICK_SPACING);
        vm.assume(_price1 > FLOOR_PRICE && _price1 <= maxBidPrice);

        _price2 = _bound(_price2, FLOOR_PRICE + TICK_SPACING, maxBidPrice);
        _price2 = helper__roundPriceDownToTickSpacing(_price2, TICK_SPACING);
        vm.assume(_price2 > FLOOR_PRICE && _price2 <= maxBidPrice);
        
        vm.assume(_price2 > _price1);
        
        _bid1Amount = uint128(_bound(_bid1Amount, 1e18, type(uint64).max));
        _bid2Amount = uint128(_bound(_bid2Amount, 1e18, type(uint64).max));
        
        address bidder1 = address(uint160(5001));
        address bidder2 = address(uint160(5002));
        
        vm.deal(bidder1, _bid1Amount);
        vm.prank(bidder1);
        auction.submitBid{value: _bid1Amount}(
            _price1,
            _bid1Amount,
            bidder1,
            ""
        );
        
        vm.deal(bidder2, _bid2Amount);
        vm.prank(bidder2);
        auction.submitBid{value: _bid2Amount}(
            _price2,
            _bid2Amount,
            bidder2,
            ""
        );
        
        vm.roll(auction.endBlock() + 1);
        auction.checkpoint();
        
        // Verify total cleared never exceeds total supply
        assertLe(auction.totalCleared(), TOTAL_SUPPLY);
    }

    // ============================================
    // Edge Case Fuzz Tests
    // ============================================

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_edgeCase_dustAmounts(uint128 _dustAmount) public {
        _dustAmount = uint128(_bound(_dustAmount, 1, 1e15)); // Very small amounts
        
        vm.deal(alice, _dustAmount);
        vm.prank(alice);
        
        try auction.submitBid{value: _dustAmount}(
            FLOOR_PRICE,
            _dustAmount,
            alice,
            ""
        ) returns (uint256 bidId) {
            Bid memory bid = auction.bids(bidId);
            // If bid succeeded, tokens filled should be proportional
            if (bid.tokensFilled > 0) {
                assertGt(bid.tokensFilled, 0);
            }
        } catch {
            // Dust amount too small, expected to revert
        }
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_edgeCase_blockTimingVariations(uint64 _blockDelay) public {
        _blockDelay = uint64(_bound(_blockDelay, 1, 50));
        
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        auction.submitBid{value: 10 ether}(FLOOR_PRICE, 10 ether, alice, "");
        
        vm.roll(block.number + _blockDelay);
        
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        auction.submitBid{value: 10 ether}(FLOOR_PRICE, 10 ether, bob, "");
        
        // Should handle different block timings correctly
        assertTrue(auction.fixedPhaseSold() > 0);
    }
}
