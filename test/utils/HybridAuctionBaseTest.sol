// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridContinuousClearingAuction} from '../../src/HybridContinuousClearingAuction.sol';
import {HybridAuctionParameters, IHybridContinuousClearingAuction} from '../../src/interfaces/IHybridContinuousClearingAuction.sol';
import {IFixedPriceStorage} from '../../src/interfaces/IFixedPriceStorage.sol';
import {ITickStorage} from '../../src/interfaces/ITickStorage.sol';
import {ITokenCurrencyStorage} from '../../src/interfaces/ITokenCurrencyStorage.sol';
import {Bid, BidLib} from '../../src/libraries/BidLib.sol';
import {Checkpoint} from '../../src/libraries/CheckpointLib.sol';
import {CheckpointLib} from '../../src/libraries/CheckpointLib.sol';
import {ConstantsLib} from '../../src/libraries/ConstantsLib.sol';
import {Currency} from '../../src/libraries/CurrencyLibrary.sol';
import {FixedPoint96} from '../../src/libraries/FixedPoint96.sol';
import {MaxBidPriceLib} from '../../src/libraries/MaxBidPriceLib.sol';
import {ValueX7, ValueX7Lib} from '../../src/libraries/ValueX7Lib.sol';
import {Assertions} from './Assertions.sol';
import {AuctionStepsBuilder} from './AuctionStepsBuilder.sol';
import {FuzzHybridDeploymentParams, FuzzBid} from './FuzzStructs.sol';
import {MockToken} from './MockToken.sol';
import {TickBitmap, TickBitmapLib} from './TickBitmap.sol';
import {TokenHandler} from './TokenHandler.sol';
import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {FixedPointMathLib} from 'solady/utils/FixedPointMathLib.sol';
import {SafeCastLib} from 'solady/utils/SafeCastLib.sol';

/// @notice Base test contract for Hybrid Auction following Uniswap's patterns
abstract contract HybridAuctionBaseTest is TokenHandler, Assertions, Test {
    using FixedPointMathLib for *;
    using AuctionStepsBuilder for bytes;
    using TickBitmapLib for TickBitmap;
    using ValueX7Lib for *;
    using BidLib for *;

    TickBitmap private tickBitmap;

    HybridContinuousClearingAuction public auction;

    // Auction configuration constants
    uint256 public constant AUCTION_DURATION = 100;
    uint256 public constant CLAIM_BLOCK_OFFSET = 10;
    uint256 public constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;
    uint256 public constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint128 public constant TOTAL_SUPPLY = 1000e18;
    uint256 public constant TOTAL_SUPPLY_Q96 = TOTAL_SUPPLY * FixedPoint96.Q96;

    // Common test values
    uint24 public constant STANDARD_MPS_1_PERCENT = 100_000; // 100e3 - represents 1% of MPS
    uint256 public constant MAX_ALLOWABLE_DUST_WEI = 1e18;

    // Test accounts
    address public alice;
    address public bob;
    address public tokensRecipient;
    address public fundsRecipient;

    HybridAuctionParameters public params;
    uint128 public totalSupply;
    FuzzHybridDeploymentParams public $deploymentParams;
    bytes public auctionStepsData;

    uint128 public $bidAmount;
    uint256 public $maxPrice;

    // ============================================
    // Fuzz Parameter Validation Helpers
    // ============================================

    function _randomUint128() private returns (uint128) {
        return uint128(bound(uint256(vm.randomUint() >> 128), 1, type(uint128).max));
    }

    function _getRandomDivisorOfMPS() private returns (uint8) {
        uint8[] memory validDivisors = new uint8[](20);
        validDivisors[0] = 1;
        validDivisors[1] = 2;
        validDivisors[2] = 4;
        validDivisors[3] = 5;
        validDivisors[4] = 8;
        validDivisors[5] = 10;
        validDivisors[6] = 16;
        validDivisors[7] = 20;
        validDivisors[8] = 25;
        validDivisors[9] = 32;
        validDivisors[10] = 40;
        validDivisors[11] = 50;
        validDivisors[12] = 64;
        validDivisors[13] = 80;
        validDivisors[14] = 100;
        validDivisors[15] = 125;
        validDivisors[16] = 128;
        validDivisors[17] = 160;
        validDivisors[18] = 200;
        validDivisors[19] = 250;

        uint256 randomIndex = _bound(uint256(vm.randomUint()), 0, validDivisors.length - 1);
        return validDivisors[randomIndex];
    }

    function helper__validInvariantDeploymentParams() public returns (FuzzHybridDeploymentParams memory) {
        FuzzHybridDeploymentParams memory deploymentParams;

        _setHardcodedParams(deploymentParams);

        deploymentParams.totalSupply = uint128(_bound(_randomUint128(), 1, ConstantsLib.MAX_TOTAL_SUPPLY));
        deploymentParams.numberOfSteps = _getRandomDivisorOfMPS();

        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(deploymentParams.totalSupply);
        deploymentParams.auctionParams.floorPrice = uint128(
            _bound(uint256(vm.randomUint()), ConstantsLib.MIN_FLOOR_PRICE, maxBidPrice - ConstantsLib.MIN_TICK_SPACING)
        );
        deploymentParams.auctionParams.tickSpacing = uint256(
            _bound(
                uint256(vm.randomUint()),
                ConstantsLib.MIN_TICK_SPACING,
                maxBidPrice - deploymentParams.auctionParams.floorPrice
            )
        );
        deploymentParams.auctionParams.tickSpacing = _bound(
            deploymentParams.auctionParams.tickSpacing,
            ConstantsLib.MIN_TICK_SPACING,
            deploymentParams.auctionParams.floorPrice
        );

        deploymentParams.auctionParams.floorPrice = helper__roundPriceDownToTickSpacing(
            deploymentParams.auctionParams.floorPrice, deploymentParams.auctionParams.tickSpacing
        );

        deploymentParams.auctionParams.startBlock = uint64(_bound(uint256(vm.randomUint()), 1, type(uint64).max));
        _boundBlockNumbers(deploymentParams);

        deploymentParams.auctionParams.auctionStepsData = _generateAuctionSteps(deploymentParams.numberOfSteps);
        
        // Hybrid-specific: bound fixed price parameters
        _boundFixedPriceParams(deploymentParams);

        $deploymentParams = deploymentParams;
        return deploymentParams;
    }

    function helper__validFuzzDeploymentParams(FuzzHybridDeploymentParams memory _deploymentParams)
        public
        returns (HybridAuctionParameters memory)
    {
        _setHardcodedParams(_deploymentParams);
        _deploymentParams.totalSupply = uint128(_bound(_deploymentParams.totalSupply, 1, ConstantsLib.MAX_TOTAL_SUPPLY));

        _boundBlockNumbers(_deploymentParams);
        _boundPriceParams(_deploymentParams);
        _boundFixedPriceParams(_deploymentParams);

        vm.assume(_deploymentParams.numberOfSteps > 0);
        vm.assume(ConstantsLib.MPS % _deploymentParams.numberOfSteps == 0);

        _deploymentParams.auctionParams.auctionStepsData = _generateAuctionSteps(_deploymentParams.numberOfSteps);

        $deploymentParams = _deploymentParams;
        totalSupply = _deploymentParams.totalSupply;
        return _deploymentParams.auctionParams;
    }

    function _setHardcodedParams(FuzzHybridDeploymentParams memory _deploymentParams) private view {
        _deploymentParams.auctionParams.currency = ETH_SENTINEL;
        _deploymentParams.auctionParams.tokensRecipient = tokensRecipient;
        _deploymentParams.auctionParams.fundsRecipient = fundsRecipient;
        _deploymentParams.auctionParams.validationHook = address(0);
    }

    function _boundBlockNumbers(FuzzHybridDeploymentParams memory _deploymentParams) private view {
        // Account for fixed price duration
        uint64 fixedDuration = _deploymentParams.auctionParams.fixedPriceBlockDuration;
        
        _deploymentParams.auctionParams.startBlock = uint64(
            _bound(
                _deploymentParams.auctionParams.startBlock,
                block.number,
                type(uint64).max - _deploymentParams.numberOfSteps - fixedDuration - 2
            )
        );
        _deploymentParams.auctionParams.endBlock =
            _deploymentParams.auctionParams.startBlock + fixedDuration + uint64(_deploymentParams.numberOfSteps);
        _deploymentParams.auctionParams.claimBlock = _deploymentParams.auctionParams.endBlock + 1;
    }

    function _boundPriceParams(FuzzHybridDeploymentParams memory _deploymentParams) private pure {
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(_deploymentParams.totalSupply);
        
        _deploymentParams.auctionParams.floorPrice = _bound(
            _deploymentParams.auctionParams.floorPrice,
            ConstantsLib.MIN_FLOOR_PRICE,
            maxBidPrice - ConstantsLib.MIN_TICK_SPACING
        );

        _deploymentParams.auctionParams.tickSpacing = _bound(
            _deploymentParams.auctionParams.tickSpacing,
            ConstantsLib.MIN_TICK_SPACING,
            maxBidPrice - _deploymentParams.auctionParams.floorPrice
        );
        
        _deploymentParams.auctionParams.floorPrice = helper__roundPriceDownToTickSpacing(
            _deploymentParams.auctionParams.floorPrice, _deploymentParams.auctionParams.tickSpacing
        );

        vm.assume(
            _deploymentParams.auctionParams.floorPrice != 0
                && _deploymentParams.auctionParams.floorPrice >= ConstantsLib.MIN_FLOOR_PRICE
        );
    }

    function _boundFixedPriceParams(FuzzHybridDeploymentParams memory _deploymentParams) private pure {
        // Bound fixed phase allocation to be <= total supply
        _deploymentParams.auctionParams.fixedPhaseTokenAllocation = uint128(
            _bound(
                _deploymentParams.auctionParams.fixedPhaseTokenAllocation,
                0,
                _deploymentParams.totalSupply
            )
        );
        
        // Bound fixed price block duration
        _deploymentParams.auctionParams.fixedPriceBlockDuration = uint64(
            _bound(
                _deploymentParams.auctionParams.fixedPriceBlockDuration,
                0,
                _deploymentParams.numberOfSteps
            )
        );
        
        // Ensure at least one transition condition if not pure CCA
        if (_deploymentParams.auctionParams.fixedPhaseTokenAllocation == 0 
            && _deploymentParams.auctionParams.fixedPriceBlockDuration == 0) {
            // Pure CCA mode - this is valid
        }
    }

    function _generateAuctionSteps(uint256 numberOfSteps) private pure returns (bytes memory) {
        uint256 mpsPerStep = ConstantsLib.MPS / numberOfSteps;
        bytes memory stepsData = new bytes(0);
        for (uint8 i = 0; i < numberOfSteps; i++) {
            stepsData = AuctionStepsBuilder.addStep(stepsData, uint24(mpsPerStep), uint40(1));
        }
        return stepsData;
    }

    // ============================================
    // Block Management Helpers
    // ============================================

    function helper__goToAuctionStartBlock() public {
        vm.roll(auction.startBlock());
    }

    function helper__maybeRollToNextBlock(uint256 _iteration) internal {
        uint256 endBlock = auction.endBlock();

        uint256 rand = uint256(keccak256(abi.encode(block.prevrandao, _iteration)));
        bool rollToNextBlock = rand & 0x3 == 0;
        
        if (rollToNextBlock && block.number < endBlock - 1) {
            vm.roll(block.number + 1);
        }
    }

    // ============================================
    // Price Calculation Helpers
    // ============================================

    function helper__roundPriceDownToTickSpacing(uint256 _price, uint256 _tickSpacing) internal pure returns (uint256) {
        return _price - (_price % _tickSpacing);
    }

    function helper__roundPriceUpToTickSpacing(uint256 _price, uint256 _tickSpacing) internal pure returns (uint256) {
        uint256 remainder = _price % _tickSpacing;
        if (remainder != 0) {
            require(
                _price <= type(uint256).max - (_tickSpacing - remainder),
                'helper__roundPriceUpToTickSpacing: Price would overflow uint256'
            );
            return _price + (_tickSpacing - remainder);
        }
        return _price;
    }

    function helper__maxPriceMultipleOfTickSpacingAboveFloorPrice(uint256 _tickNumber)
        internal
        view
        returns (uint256 maxPrice)
    {
        uint256 tickSpacing = params.tickSpacing;
        uint256 floorPrice = params.floorPrice;

        if (_tickNumber == 0) return floorPrice;

        maxPrice = _bound(floorPrice + (_tickNumber * tickSpacing), floorPrice, type(uint256).max);
    }

    function helper__assumeValidMaxPrice(
        uint256 _floorPrice,
        uint256 _maxPrice,
        uint128 _totalSupply,
        uint256 _tickSpacing
    ) internal pure returns (uint256) {
        vm.assume(_totalSupply != 0 && _tickSpacing != 0 && _floorPrice != 0 && _maxPrice != 0);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(_totalSupply);
        vm.assume(_floorPrice + _tickSpacing <= maxBidPrice);
        _maxPrice = _bound(_maxPrice, _floorPrice + _tickSpacing, maxBidPrice);
        _maxPrice = helper__roundPriceDownToTickSpacing(_maxPrice, _tickSpacing);
        vm.assume(_maxPrice > _floorPrice && _maxPrice <= maxBidPrice);
        return _maxPrice;
    }

    // ============================================
    // Bid Submission Helpers
    // ============================================

    function helper__trySubmitBid(
        uint256,
        FuzzBid memory _bid,
        address _owner
    )
        internal
        returns (bool bidPlaced, uint256 bidId)
    {
        Checkpoint memory latestCheckpoint = auction.checkpoint();
        uint256 clearingPrice = latestCheckpoint.clearingPrice;

        uint256 maxPrice = helper__maxPriceMultipleOfTickSpacingAboveFloorPrice(_bid.tickNumber);
        
        // In fixed price phase, check against fixed price
        uint128 ethInputAmount;
        if (auction.isFixedPricePhase()) {
            if (maxPrice < auction.fixedPrice()) return (false, 0);
            ethInputAmount = inputAmountForTokens(_bid.bidAmount, maxPrice);
            
            try auction.submitBid{value: ethInputAmount}(
                maxPrice, ethInputAmount, _owner, bytes('')
            ) returns (uint256 _bidId) {
                bidId = _bidId;
                return (true, bidId);
            } catch {
                return (false, 0);
            }
        }
        
        // CCA phase logic
        if (maxPrice <= clearingPrice) return (false, 0);
        
        maxPrice =
            helper__assumeValidMaxPrice(auction.floorPrice(), maxPrice, auction.ccaTotalSupply(), auction.tickSpacing());
        ethInputAmount = inputAmountForTokens(_bid.bidAmount, maxPrice);

        vm.assume(
            auction.sumCurrencyDemandAboveClearingQ96()
                < ConstantsLib.X7_UPPER_BOUND - (ethInputAmount * FixedPoint96.Q96 * ConstantsLib.MPS)
                    / (ConstantsLib.MPS - latestCheckpoint.cumulativeMps)
        );

        uint256 lowerTickNumber = tickBitmap.findPrev(_bid.tickNumber);
        uint256 lastTickPrice = helper__maxPriceMultipleOfTickSpacingAboveFloorPrice(lowerTickNumber);
        if (lastTickPrice > maxPrice) {
            lastTickPrice = auction.floorPrice();
        }

        try auction.submitBid{value: ethInputAmount}(
            maxPrice, ethInputAmount, _owner, lastTickPrice, bytes('')
        ) returns (uint256 _bidId) {
            bidId = _bidId;
        } catch (bytes memory revertData) {
            if (_shouldSkipBidError(revertData, maxPrice)) {
                return (false, 0);
            }
            assembly {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }

        tickBitmap.set(_bid.tickNumber);
        return (true, bidId);
    }

    function _shouldSkipBidError(bytes memory revertData, uint256 maxPrice) private returns (bool) {
        bytes4 errorSelector = bytes4(revertData);

        if (
            errorSelector
                == bytes4(abi.encodeWithSelector(IHybridContinuousClearingAuction.BidMustBeAboveClearingPrice.selector))
        ) {
            Checkpoint memory checkpoint = auction.checkpoint();
            if (maxPrice <= checkpoint.clearingPrice) return true;
            revert('Uncaught BidMustBeAboveClearingPrice');
        }
        
        if (
            errorSelector
                == bytes4(abi.encodeWithSelector(IHybridContinuousClearingAuction.BidBelowFixedPrice.selector))
        ) {
            return true;
        }

        return false;
    }

    // ============================================
    // Test Setup Functions & Modifiers
    // ============================================

    modifier setUpBidsFuzz(FuzzBid[] memory _bids) {
        for (uint256 i = 0; i < _bids.length; i++) {
            _bids[i].bidAmount = uint64(_bound(_bids[i].bidAmount, 1, type(uint64).max));
            _bids[i].tickNumber = uint8(_bound(_bids[i].tickNumber, 1, type(uint8).max));
        }
        _;
    }

    modifier requireAuctionNotSetup() {
        require(address(auction) == address(0), 'Auction already setup');
        _;
    }

    modifier givenAuctionHasStarted() {
        helper__goToAuctionStartBlock();
        _;
    }

    modifier givenFullyFundedAccount() {
        vm.deal(address(this), uint256(type(uint256).max));
        _;
    }

    modifier setUpAuctionFuzz(FuzzHybridDeploymentParams memory _deploymentParams) {
        setUpAuction(_deploymentParams);
        _;
    }

    // Fuzzing variant of setUpAuction
    function setUpAuction(FuzzHybridDeploymentParams memory _deploymentParams) public requireAuctionNotSetup {
        setUpTokens();

        alice = makeAddr('alice');
        bob = makeAddr('bob');
        tokensRecipient = makeAddr('tokensRecipient');
        fundsRecipient = makeAddr('fundsRecipient');

        params = helper__validFuzzDeploymentParams(_deploymentParams);

        vm.expectEmit(true, true, true, true);
        emit ITickStorage.TickInitialized(_deploymentParams.auctionParams.floorPrice);
        auction = new HybridContinuousClearingAuction(address(token), _deploymentParams.totalSupply, params);

        token.mint(address(auction), _deploymentParams.totalSupply);
        auction.onTokensReceived();
    }

    // Non-fuzzing variant of setUpAuction
    function setUpAuction() public requireAuctionNotSetup {
        setUpTokens();

        alice = makeAddr('alice');
        bob = makeAddr('bob');
        tokensRecipient = makeAddr('tokensRecipient');
        fundsRecipient = makeAddr('fundsRecipient');

        // Default: 30% fixed price, 70% CCA
        uint128 fixedPhaseAllocation = (TOTAL_SUPPLY * 30) / 100;

        auctionStepsData =
            AuctionStepsBuilder.init().addStep(STANDARD_MPS_1_PERCENT, 50).addStep(STANDARD_MPS_1_PERCENT, 50);
        
        params = HybridAuctionParameters({
            currency: ETH_SENTINEL,
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 150), // 50 fixed + 100 CCA
            claimBlock: uint64(block.number + 150 + CLAIM_BLOCK_OFFSET),
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: auctionStepsData,
            fixedPhaseTokenAllocation: fixedPhaseAllocation,
            fixedPriceBlockDuration: 50
        });

        vm.expectEmit(true, true, true, true);
        emit ITickStorage.TickInitialized(tickNumberToPriceX96(1));
        auction = new HybridContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);

        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();
    }

    // ============================================
    // Bid & Price Validation Modifiers
    // ============================================

    modifier givenValidMaxPrice(uint256 _maxPrice, uint128 _totalSupply) {
        $maxPrice = helper__assumeValidMaxPrice(FLOOR_PRICE, _maxPrice, _totalSupply, TICK_SPACING);
        _;
    }

    modifier givenValidMaxPriceWithParams(
        uint256 _maxPrice,
        uint128 _totalSupply,
        uint256 _floorPrice,
        uint256 _tickSpacing
    ) {
        $maxPrice = helper__assumeValidMaxPrice(_floorPrice, _maxPrice, _totalSupply, _tickSpacing);
        _;
    }

    modifier givenValidBidAmount(uint128 _bidAmount) {
        $bidAmount = SafeCastLib.toUint128(_bound(_bidAmount, 1, type(uint128).max));
        _;
    }

    modifier givenGraduatedAuction() {
        uint256 maxCurrencyRaised = uint256($deploymentParams.totalSupply).fullMulDiv($maxPrice, FixedPoint96.Q96);
        vm.assume(params.requiredCurrencyRaised <= maxCurrencyRaised);
        vm.assume($bidAmount >= params.requiredCurrencyRaised);
        _;
    }

    modifier givenNotGraduatedAuction() {
        vm.assume($bidAmount < params.requiredCurrencyRaised);
        _;
    }

    modifier checkAuctionIsSolvent() {
        _;
        require(block.number >= auction.endBlock(), 'checkAuctionIsSolvent: Auction is not over');
        auction.checkpoint();
        if (auction.isGraduated()) {
            assertLe(auction.totalCleared(), auction.totalSupply(), 'total cleared must be <= total supply');

            auction.sweepCurrency();
            auction.sweepUnsoldTokens();
            
            assertApproxEqAbs(
                token.balanceOf(address(auction)),
                0,
                MAX_ALLOWABLE_DUST_WEI,
                'Auction should have less than MAX_ALLOWABLE_DUST_WEI tokens left'
            );
            assertApproxEqAbs(
                address(auction).balance,
                0,
                MAX_ALLOWABLE_DUST_WEI,
                'Auction should have less than MAX_ALLOWABLE_DUST_WEI wei left of currency'
            );
        } else {
            auction.sweepUnsoldTokens();
            assertEq(token.balanceOf(auction.tokensRecipient()), auction.totalSupply());
            
            vm.expectRevert(ITokenCurrencyStorage.NotGraduated.selector);
            auction.sweepCurrency();
        }
    }

    modifier checkAuctionIsGraduated() {
        _;
        require(block.number >= auction.endBlock(), 'checkAuctionIsGraduated: Auction is not over');
        auction.checkpoint();
        assertTrue(auction.isGraduated());
    }

    modifier checkAuctionIsNotGraduated() {
        _;
        require(block.number >= auction.endBlock(), 'checkAuctionIsNotGraduated: Auction is not over');
        auction.checkpoint();
        assertFalse(auction.isGraduated());
    }

    function helper__submitBid(HybridContinuousClearingAuction _auction, address _owner, uint128 _amount, uint256 _maxPrice)
        internal
        returns (uint256)
    {
        return _auction.submitBid{value: _amount}(_maxPrice, _amount, _owner, params.floorPrice, bytes(''));
    }

    function helper__submitNBids(
        HybridContinuousClearingAuction _auction,
        address _owner,
        uint128 _amount,
        uint128 _numberOfBids,
        uint256 _maxPrice
    ) internal returns (uint256[] memory) {
        uint128 amountPerBid = _amount / _numberOfBids;

        uint256[] memory bids = new uint256[](_numberOfBids);
        for (uint256 i = 0; i < _numberOfBids; i++) {
            bids[i] = helper__submitBid(_auction, _owner, amountPerBid, _maxPrice);
        }
        return bids;
    }

    function tickNumberToPriceX96(uint256 tickNumber) internal pure returns (uint256) {
        return FLOOR_PRICE + (tickNumber - 1) * TICK_SPACING;
    }

    function inputAmountForTokens(uint128 tokens, uint256 maxPrice) internal pure returns (uint128) {
        uint256 temp = tokens.fullMulDivUp(maxPrice, FixedPoint96.Q96);
        temp = _bound(temp, 1, type(uint128).max);
        return SafeCastLib.toUint128(temp);
    }
}
