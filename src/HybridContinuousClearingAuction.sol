// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BidStorage} from './BidStorage.sol';
import {Checkpoint, CheckpointStorage} from './CheckpointStorage.sol';
import {FixedPriceStorage} from './FixedPriceStorage.sol';
import {StepStorage} from './StepStorage.sol';
import {Tick, TickStorage} from './TickStorage.sol';
import {TokenCurrencyStorage} from './TokenCurrencyStorage.sol';
import {HybridAuctionParameters, IHybridContinuousClearingAuction} from './interfaces/IHybridContinuousClearingAuction.sol';
import {IValidationHook} from './interfaces/IValidationHook.sol';
import {IDistributionContract} from './interfaces/external/IDistributionContract.sol';
import {Bid, BidLib} from './libraries/BidLib.sol';
import {CheckpointLib} from './libraries/CheckpointLib.sol';
import {ConstantsLib} from './libraries/ConstantsLib.sol';
import {Currency, CurrencyLibrary} from './libraries/CurrencyLibrary.sol';
import {FixedPoint96} from './libraries/FixedPoint96.sol';
import {MaxBidPriceLib} from './libraries/MaxBidPriceLib.sol';
import {AuctionStep, StepLib} from './libraries/StepLib.sol';
import {ValidationHookLib} from './libraries/ValidationHookLib.sol';
import {ValueX7, ValueX7Lib} from './libraries/ValueX7Lib.sol';
import {FixedPointMathLib} from 'solady/utils/FixedPointMathLib.sol';
import {SafeTransferLib} from 'solady/utils/SafeTransferLib.sol';

/// @title HybridContinuousClearingAuction V2
/// @notice Implements a hybrid auction: simple FCFS fixed price phase followed by CCA
/// @dev Fixed price phase fills orders immediately without continuous clearing
///      After transition, remaining tokens are sold via standard CCA mechanism
contract HybridContinuousClearingAuction is
    BidStorage,
    CheckpointStorage,
    FixedPriceStorage,
    StepStorage,
    TickStorage,
    TokenCurrencyStorage,
    IHybridContinuousClearingAuction
{
    using FixedPointMathLib for *;
    using CurrencyLibrary for Currency;
    using BidLib for *;
    using StepLib for *;
    using CheckpointLib for Checkpoint;
    using ValidationHookLib for IValidationHook;
    using ValueX7Lib for *;

    /// @notice The maximum price which a bid can be submitted at
    uint256 public immutable MAX_BID_PRICE;
    /// @notice The block at which purchased tokens can be claimed
    uint64 internal immutable CLAIM_BLOCK;
    /// @notice An optional hook to be called before a bid is registered
    IValidationHook internal immutable VALIDATION_HOOK;

    /// @notice The total currency raised in the auction in Q96 representation, scaled up by X7
    ValueX7 internal $currencyRaisedQ96_X7;
    /// @notice The total tokens sold in the auction (including fixed price phase)
    ValueX7 internal $totalClearedQ96_X7;
    /// @notice The sum of currency demand in ticks above the clearing price (CCA phase only)
    uint256 internal $sumCurrencyDemandAboveClearingQ96;
    /// @notice Whether the TOTAL_SUPPLY of tokens has been received
    bool private $_tokensReceived;

    constructor(address _token, uint128 _totalSupply, HybridAuctionParameters memory _parameters)
        StepStorage(_parameters.auctionStepsData, _parameters.startBlock, _parameters.endBlock)
        TokenCurrencyStorage(
            _token,
            _parameters.currency,
            _totalSupply,
            _parameters.tokensRecipient,
            _parameters.fundsRecipient,
            _parameters.requiredCurrencyRaised
        )
        TickStorage(_parameters.tickSpacing, _parameters.floorPrice)
    {
        MAX_BID_PRICE = MaxBidPriceLib.maxBidPrice(_totalSupply);
        
        _initializeFixedPriceStorage(
            _parameters.floorPrice,
            _parameters.fixedPhaseTokenAllocation,
            _parameters.fixedPriceBlockDuration,
            _parameters.startBlock,
            _parameters.endBlock,
            MAX_BID_PRICE,
            _totalSupply
        );
        
        CLAIM_BLOCK = _parameters.claimBlock;
        VALIDATION_HOOK = IValidationHook(_parameters.validationHook);

        if (CLAIM_BLOCK < END_BLOCK) revert ClaimBlockIsBeforeEndBlock();

        if (_parameters.tickSpacing > MAX_BID_PRICE || _parameters.floorPrice > MAX_BID_PRICE - _parameters.tickSpacing)
        {
            revert FloorPriceAndTickSpacingGreaterThanMaxBidPrice(
                _parameters.floorPrice + _parameters.tickSpacing, MAX_BID_PRICE
            );
        }
        
        // Initialize CCA phase immediately for pure CCA auctions
        if (_parameters.fixedPhaseTokenAllocation == 0 && _parameters.fixedPriceBlockDuration == 0) {
            _initializeCCASupply(_totalSupply);
            _initializeCCAPhase(uint64(_parameters.startBlock));
        }
    }

    modifier onlyAfterAuctionIsOver() {
        if (block.number < END_BLOCK) revert AuctionIsNotOver();
        _;
    }

    modifier onlyAfterClaimBlock() {
        if (block.number < CLAIM_BLOCK) revert NotClaimable();
        _;
    }

    modifier onlyActiveAuction() {
        _onlyActiveAuction();
        _;
    }

    function _onlyActiveAuction() internal view {
        if (block.number < START_BLOCK) revert AuctionNotStarted();
        if (!$_tokensReceived) revert TokensNotReceived();
    }

    modifier ensureEndBlockIsCheckpointed() {
        if ($lastCheckpointedBlock != END_BLOCK) {
            checkpoint();
        }
        _;
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if ($_tokensReceived) return;
        if (TOKEN.balanceOf(address(this)) < TOTAL_SUPPLY) {
            revert InvalidTokenAmountReceived();
        }
        $_tokensReceived = true;
        emit TokensReceived(TOTAL_SUPPLY);

    }

    /// @notice Override to add CCA initialization during transition
    /// @param blockNumber The block number when transition occurs
    function _executeTransition(uint64 blockNumber) internal override {
        // Call parent to update fixed price phase state
        super._executeTransition(blockNumber);
        
        // Calculate remaining tokens for CCA phase
        uint128 remainingTokens = TOTAL_SUPPLY - $_fixedPhaseSold;
        
        if (remainingTokens == 0) revert NoTokensRemainingForCCA();
        
        // Initialize CCA phase with remaining tokens
        _initializeCCASupply(remainingTokens);
        _initializeCCAPhase(blockNumber);
        
        emit TransitionToCCAWithDetails(
            blockNumber,
            $_fixedPhaseSold,
            FIXED_PRICE
        );
    }

    /// @notice Check if transition conditions are met and execute transition
    /// @return transitioned Whether transition occurred
    function _checkAndExecuteTransition() internal returns (bool transitioned) {
        if (!_isFixedPricePhase()) return false;

        uint64 currentBlock = uint64(block.number);
        
        (bool tokenAllocationMet, bool blockDurationMet) = _checkTransitionConditions(currentBlock);

        if (tokenAllocationMet || blockDurationMet) {
            // Determine transition block: use fixedPriceEndBlock if time expired, otherwise current block
            uint64 transitionBlock = blockDurationMet 
                ? FIXED_PRICE_END_BLOCK  // Time-based transition: happened at the deadline
                : currentBlock;         // Allocation-based transition: happening now
            
            _executeTransition(transitionBlock);
            return true;
        }
        
        return false;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function isGraduated() external view returns (bool) {
        return _isGraduated();
    }

    function _isGraduated() internal view returns (bool) {
        return ValueX7.unwrap($currencyRaisedQ96_X7) >= ValueX7.unwrap(REQUIRED_CURRENCY_RAISED_Q96_X7);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function requiredCurrencyRaised() external view returns (uint256) {
        return _requiredCurrencyRaised();
    }

    function _requiredCurrencyRaised() internal view returns (uint256) {
        return REQUIRED_CURRENCY_RAISED_Q96_X7.divUint256(FixedPoint96.Q96).scaleDownToUint256();
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function currencyRaised() external view returns (uint256) {
        return _currencyRaised();
    }

    function _currencyRaised() internal view returns (uint256) {
        return $currencyRaisedQ96_X7.divUint256(FixedPoint96.Q96).scaleDownToUint256();
    }

    /// @notice Process a fixed price order - fills immediately on FCFS basis
    /// @param amount The amount of currency to spend
    /// @param owner The owner of the order
    /// @return bidId The id of the created bid/order
    /// @return tokensFilled The amount of tokens filled
    function _processFixedPriceOrder(uint128 amount, address owner)
        internal
        returns (uint256 bidId, uint128 tokensFilled)
    {
        // Calculate how many tokens this order can buy at fixed price
        // tokenAmount = currencyAmount / price
        // Since price is in Q96: tokenAmount = (currencyAmount * Q96) / price
        uint256 tokensRequested = (uint256(amount) * FixedPoint96.Q96) / FIXED_PRICE;
        
        // Check how many tokens are available
        uint128 tokensAvailable = _getFixedPhaseRemainingTokens();
        
        // Fill as much as possible
        tokensFilled = uint128(FixedPointMathLib.min(tokensRequested, tokensAvailable));
        
        if (tokensFilled == 0) revert NoFixedPriceTokensAvailable();
        
        // Calculate actual currency spent (may be less than amount if partially filled)
        uint256 currencySpent = (uint256(tokensFilled) * FIXED_PRICE) / FixedPoint96.Q96;
        uint256 currencySpentQ96 = currencySpent << FixedPoint96.RESOLUTION;
        
        // Record the sale
        _recordFixedPhaseSale(tokensFilled);
        
        // Update currency raised
        uint256 currencyRaisedQ96X7 = currencySpentQ96 * ConstantsLib.MPS;
        $currencyRaisedQ96_X7 = ValueX7.wrap(ValueX7.unwrap($currencyRaisedQ96_X7) + currencyRaisedQ96X7);
        
        // Update total cleared
        uint256 tokensClearedQ96X7 = (uint256(tokensFilled) << FixedPoint96.RESOLUTION) * ConstantsLib.MPS;
        $totalClearedQ96_X7 = ValueX7.wrap(ValueX7.unwrap($totalClearedQ96_X7) + tokensClearedQ96X7);
        
        // Create bid record (with special handling for fixed price orders)
        // For fixed price orders, startCumulativeMps is 0 since they don't participate in MPS schedule
        uint256 amountQ96 = uint256(amount) << FixedPoint96.RESOLUTION;
        Bid memory bid;
        (bid, bidId) = _createBid(amountQ96, owner, FIXED_PRICE, 0);
        
        // Mark as immediately exited and set tokens filled
        // We need to update the stored bid directly
        Bid storage $bid = _getBid(bidId);
        $bid.exitedBlock = uint64(block.number);
        $bid.tokensFilled = tokensFilled;
        
        // Process refund for any unfilled amount
        uint256 refund = amount - uint128(currencySpent);
        if (refund > 0) {
            CURRENCY.transfer(owner, refund);
        }
        
        emit FixedPriceOrderFilled(bidId, owner, tokensFilled, uint128(currencySpent), uint128(refund));
    }

    /// @notice Sell tokens at clearing price during CCA phase
    function _sellTokensAtClearingPrice(Checkpoint memory _checkpoint, uint24 deltaMps)
        internal
        returns (Checkpoint memory)
    {
        uint256 priceQ96 = _checkpoint.clearingPrice;
        uint256 deltaMpsU = uint256(deltaMps);
        uint256 sumAboveQ96 = $sumCurrencyDemandAboveClearingQ96;

        uint256 currencyFromAboveQ96X7;
        unchecked {
            currencyFromAboveQ96X7 = sumAboveQ96 * deltaMpsU;
        }

        if (priceQ96 % TICK_SPACING == 0) {
            uint256 demandAtPriceQ96 = _getTick(priceQ96).currencyDemandQ96;
            if (demandAtPriceQ96 > 0) {
                uint256 currencyRaisedAboveClearingQ96X7 = currencyFromAboveQ96X7;
                uint256 totalCurrencyForDeltaQ96X7;
                unchecked {
                    totalCurrencyForDeltaQ96X7 = (uint256(CCA_TOTAL_SUPPLY) * priceQ96) * deltaMpsU;
                }
                uint256 demandAtClearingQ96X7 = totalCurrencyForDeltaQ96X7 - currencyRaisedAboveClearingQ96X7;
                uint256 expectedAtClearingTickQ96X7;
                unchecked {
                    expectedAtClearingTickQ96X7 = demandAtPriceQ96 * deltaMpsU;
                }
                uint256 currencyAtClearingTickQ96X7 =
                    FixedPointMathLib.min(demandAtClearingQ96X7, expectedAtClearingTickQ96X7);
                currencyFromAboveQ96X7 = currencyAtClearingTickQ96X7 + currencyRaisedAboveClearingQ96X7;
                _checkpoint.currencyRaisedAtClearingPriceQ96_X7 = ValueX7.wrap(
                    ValueX7.unwrap(_checkpoint.currencyRaisedAtClearingPriceQ96_X7) + currencyAtClearingTickQ96X7
                );
            }
        }

        uint256 tokensClearedQ96X7 = currencyFromAboveQ96X7.fullMulDivUp(FixedPoint96.Q96, priceQ96);
        $totalClearedQ96_X7 = ValueX7.wrap(ValueX7.unwrap($totalClearedQ96_X7) + tokensClearedQ96X7);
        $currencyRaisedQ96_X7 = ValueX7.wrap(ValueX7.unwrap($currencyRaisedQ96_X7) + currencyFromAboveQ96X7);

        _checkpoint.cumulativeMps += deltaMps;
        _checkpoint.cumulativeMpsPerPrice += CheckpointLib.getMpsPerPrice(deltaMps, priceQ96);
        return _checkpoint;
    }

    function _advanceToStartOfCurrentStep(uint64 _blockNumber, uint64 _lastCheckpointedBlock)
        internal
        returns (AuctionStep memory step, uint24 deltaMps)
    {
        step = $step;
        uint64 start = uint64(FixedPointMathLib.max(step.startBlock, _lastCheckpointedBlock));
        uint64 end = step.endBlock;

        uint24 mps = step.mps;
        while (_blockNumber > end) {
            uint64 blockDelta = end - start;
            unchecked {
                deltaMps += uint24(blockDelta * mps);
            }
            start = end;
            if (end == END_BLOCK) break;
            step = _advanceStep();
            mps = step.mps;
            end = step.endBlock;
        }
    }

    function _iterateOverTicksAndFindClearingPrice(Checkpoint memory _checkpoint) internal returns (uint256) {
        uint256 minimumClearingPrice = _checkpoint.clearingPrice.coalesce(FLOOR_PRICE);
        if (_checkpoint.remainingMpsInAuction() == 0) {
            return minimumClearingPrice;
        }

        bool updateStateVariables;
        uint256 sumCurrencyDemandAboveClearingQ96_ = $sumCurrencyDemandAboveClearingQ96;
        uint256 nextActiveTickPrice_ = $nextActiveTickPrice;

        uint256 clearingPrice = sumCurrencyDemandAboveClearingQ96_.divUp(CCA_TOTAL_SUPPLY);
        while (
            (nextActiveTickPrice_ != MAX_TICK_PTR
                    && sumCurrencyDemandAboveClearingQ96_ >= CCA_TOTAL_SUPPLY * nextActiveTickPrice_)
                || clearingPrice == nextActiveTickPrice_
        ) {
            Tick storage $nextActiveTick = _getTick(nextActiveTickPrice_);
            sumCurrencyDemandAboveClearingQ96_ -= $nextActiveTick.currencyDemandQ96;
            minimumClearingPrice = nextActiveTickPrice_;
            nextActiveTickPrice_ = $nextActiveTick.next;
            clearingPrice = sumCurrencyDemandAboveClearingQ96_.divUp(CCA_TOTAL_SUPPLY);
            updateStateVariables = true;
        }
        
        if (updateStateVariables) {
            $sumCurrencyDemandAboveClearingQ96 = sumCurrencyDemandAboveClearingQ96_;
            $nextActiveTickPrice = nextActiveTickPrice_;
            emit NextActiveTickUpdated(nextActiveTickPrice_);
        }

        if (clearingPrice < minimumClearingPrice) {
            return minimumClearingPrice;
        } else {
            return clearingPrice;
        }
    }

    function _checkpointAtBlock(uint64 blockNumber) internal returns (Checkpoint memory _checkpoint) {
        uint64 lastCheckpointedBlock = $lastCheckpointedBlock;
        if (blockNumber == lastCheckpointedBlock) return latestCheckpoint();

        _checkpoint = latestCheckpoint();
        
        // Check for transition
        _checkAndExecuteTransition();
        
        // Only do CCA checkpoint logic if we're in CCA phase
        if (!_isFixedPricePhase()) {
            uint256 clearingPrice = _iterateOverTicksAndFindClearingPrice(_checkpoint);
            
            if (clearingPrice != _checkpoint.clearingPrice) {
                _checkpoint.clearingPrice = clearingPrice;
                _checkpoint.currencyRaisedAtClearingPriceQ96_X7 = ValueX7.wrap(0);
                emit ClearingPriceUpdated(blockNumber, clearingPrice);
            }

            (AuctionStep memory step, uint24 deltaMps) = _advanceToStartOfCurrentStep(blockNumber, lastCheckpointedBlock);
            uint64 blockDelta = blockNumber - uint64(FixedPointMathLib.max(step.startBlock, lastCheckpointedBlock));
            unchecked {
                deltaMps += uint24(blockDelta * step.mps);
            }

            _checkpoint = _sellTokensAtClearingPrice(_checkpoint, deltaMps);
        }
        
        _insertCheckpoint(_checkpoint, blockNumber);
        emit CheckpointUpdated(blockNumber, _checkpoint.clearingPrice, _checkpoint.cumulativeMps);
    }

    function _getFinalCheckpoint() internal returns (Checkpoint memory) {
        return _checkpointAtBlock(END_BLOCK);
    }

    function _submitBid(uint256 maxPrice, uint128 amount, address owner, uint256 prevTickPrice, bytes calldata hookData)
        internal
        returns (uint256 bidId)
    {
        // Check if we're in fixed price phase
        if (_isFixedPricePhase()) {
            // Fixed price order - validate price and process immediately
            if (maxPrice < FIXED_PRICE) revert BidBelowFixedPrice();
            
            VALIDATION_HOOK.handleValidate(FIXED_PRICE, amount, owner, msg.sender, hookData);
            
            uint128 tokensFilled;
            (bidId, tokensFilled) = _processFixedPriceOrder(amount, owner);
            
            // Check if this order triggered transition
            _checkAndExecuteTransition();
            
            return bidId;
        }
        
        // CCA phase - normal bidding logic
        if (maxPrice > MAX_BID_PRICE) revert InvalidBidPriceTooHigh(maxPrice, MAX_BID_PRICE);

        Checkpoint memory _checkpoint = checkpoint();
        if (_checkpoint.remainingMpsInAuction() == 0) revert AuctionSoldOut();
        if (maxPrice <= _checkpoint.clearingPrice) revert BidMustBeAboveClearingPrice();

        _initializeTickIfNeeded(prevTickPrice, maxPrice);
        VALIDATION_HOOK.handleValidate(maxPrice, amount, owner, msg.sender, hookData);

        Bid memory bid;
        uint256 amountQ96 = uint256(amount) << FixedPoint96.RESOLUTION;
        (bid, bidId) = _createBid(amountQ96, owner, maxPrice, _checkpoint.cumulativeMps);

        uint256 bidEffectiveAmountQ96 = bid.toEffectiveAmount();
        _updateTickDemand(maxPrice, bidEffectiveAmountQ96);
        $sumCurrencyDemandAboveClearingQ96 += bidEffectiveAmountQ96;

        if ($sumCurrencyDemandAboveClearingQ96 >= ConstantsLib.X7_UPPER_BOUND) {
            revert InvalidBidUnableToClear();
        }

        emit BidSubmitted(bidId, owner, maxPrice, amount);
    }

    function _processExit(uint256 bidId, uint256 tokensFilled, uint256 currencySpentQ96) internal {
        Bid storage $bid = _getBid(bidId);
        address _owner = $bid.owner;

        uint256 refund = ($bid.amountQ96 - currencySpentQ96) >> FixedPoint96.RESOLUTION;

        $bid.tokensFilled = tokensFilled;
        $bid.exitedBlock = uint64(block.number);

        if (refund > 0) {
            CURRENCY.transfer(_owner, refund);
        }

        emit BidExited(bidId, _owner, tokensFilled, refund);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function checkpoint() public onlyActiveAuction returns (Checkpoint memory) {
        if (block.number > END_BLOCK) {
            return _getFinalCheckpoint();
        } else {
            return _checkpointAtBlock(uint64(block.number));
        }
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function submitBid(uint256 maxPrice, uint128 amount, address owner, uint256 prevTickPrice, bytes calldata hookData)
        public
        payable
        onlyActiveAuction
        returns (uint256)
    {
        if (block.number >= END_BLOCK) revert AuctionIsOver();
        if (amount == 0) revert BidAmountTooSmall();
        if (owner == address(0)) revert BidOwnerCannotBeZeroAddress();
        if (CURRENCY.isAddressZero()) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert CurrencyIsNotNative();
            SafeTransferLib.permit2TransferFrom(Currency.unwrap(CURRENCY), msg.sender, address(this), amount);
        }
        return _submitBid(maxPrice, amount, owner, prevTickPrice, hookData);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function submitBid(uint256 maxPrice, uint128 amount, address owner, bytes calldata hookData)
        external
        payable
        returns (uint256)
    {
        return submitBid(maxPrice, amount, owner, FLOOR_PRICE, hookData);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function exitBid(uint256 bidId) external onlyAfterAuctionIsOver {
        Bid memory bid = _getBid(bidId);
        if (bid.exitedBlock != 0) revert BidAlreadyExited();
        
        // Fixed price orders are already exited during submission
        if (bid.maxPrice == FIXED_PRICE && bid.exitedBlock == bid.startBlock) {
            revert BidAlreadyExited();
        }
        
        Checkpoint memory finalCheckpoint = _getFinalCheckpoint();
        if (!_isGraduated()) {
            return _processExit(bidId, 0, 0);
        }
        if (bid.maxPrice <= finalCheckpoint.clearingPrice) revert CannotExitBid();

        Checkpoint memory startCheckpoint = _getCheckpoint(bid.startBlock);
        (uint256 tokensFilled, uint256 currencySpentQ96) =
            _accountFullyFilledCheckpoints(finalCheckpoint, startCheckpoint, bid);

        _processExit(bidId, tokensFilled, currencySpentQ96);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock) external {
        Checkpoint memory currentBlockCheckpoint = checkpoint();

        Bid memory bid = _getBid(bidId);
        if (bid.exitedBlock != 0) revert BidAlreadyExited();

        if (!_isGraduated()) {
            if (block.number >= END_BLOCK) {
                return _processExit(bidId, 0, 0);
            }
            revert CannotPartiallyExitBidBeforeGraduation();
        }

        uint256 bidMaxPrice = bid.maxPrice;
        uint64 bidStartBlock = bid.startBlock;

        Checkpoint memory lastFullyFilledCheckpoint = _getCheckpoint(lastFullyFilledCheckpointBlock);
        if (
            lastFullyFilledCheckpoint.clearingPrice >= bidMaxPrice
                || _getCheckpoint(lastFullyFilledCheckpoint.next).clearingPrice < bidMaxPrice
                || lastFullyFilledCheckpointBlock < bidStartBlock
        ) {
            revert InvalidLastFullyFilledCheckpointHint();
        }

        Checkpoint memory startCheckpoint = _getCheckpoint(bidStartBlock);

        uint256 tokensFilled;
        uint256 currencySpentQ96;

        if (lastFullyFilledCheckpoint.clearingPrice > 0) {
            (tokensFilled, currencySpentQ96) =
                _accountFullyFilledCheckpoints(lastFullyFilledCheckpoint, startCheckpoint, bid);
        }

        Checkpoint memory upperCheckpoint;
        if (outbidBlock != 0) {
            Checkpoint memory outbidCheckpoint;
            if (outbidBlock == block.number) {
                outbidCheckpoint = currentBlockCheckpoint;
            } else {
                outbidCheckpoint = _getCheckpoint(outbidBlock);
            }

            upperCheckpoint = _getCheckpoint(outbidCheckpoint.prev);
            if (outbidCheckpoint.clearingPrice <= bidMaxPrice || upperCheckpoint.clearingPrice > bidMaxPrice) {
                revert InvalidOutbidBlockCheckpointHint();
            }
        } else {
            if (block.number < END_BLOCK) revert CannotPartiallyExitBidBeforeEndBlock();
            upperCheckpoint = currentBlockCheckpoint;
            if (upperCheckpoint.clearingPrice != bidMaxPrice) {
                revert CannotExitBid();
            }
        }

        if (upperCheckpoint.clearingPrice == bidMaxPrice) {
            uint256 tickDemandQ96 = _getTick(bidMaxPrice).currencyDemandQ96;
            (uint256 partialTokensFilled, uint256 partialCurrencySpentQ96) = _accountPartiallyFilledCheckpoints(
                bid, tickDemandQ96, upperCheckpoint.currencyRaisedAtClearingPriceQ96_X7
            );
            tokensFilled += partialTokensFilled;
            currencySpentQ96 += partialCurrencySpentQ96;
        }

        _processExit(bidId, tokensFilled, currencySpentQ96);
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function claimTokens(uint256 _bidId) external onlyAfterClaimBlock ensureEndBlockIsCheckpointed {
        if (!_isGraduated()) revert NotGraduated();

        (address owner, uint256 tokensFilled) = _internalClaimTokens(_bidId);

        if (tokensFilled > 0) {
            Currency.wrap(address(TOKEN)).transfer(owner, tokensFilled);
            emit TokensClaimed(_bidId, owner, tokensFilled);
        }
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function claimTokensBatch(address _owner, uint256[] calldata _bidIds)
        external
        onlyAfterClaimBlock
        ensureEndBlockIsCheckpointed
    {
        if (!_isGraduated()) revert NotGraduated();

        uint256 tokensFilled = 0;
        for (uint256 i = 0; i < _bidIds.length; i++) {
            (address bidOwner, uint256 bidTokensFilled) = _internalClaimTokens(_bidIds[i]);

            if (bidOwner != _owner) {
                revert BatchClaimDifferentOwner(_owner, bidOwner);
            }

            tokensFilled += bidTokensFilled;

            if (bidTokensFilled > 0) {
                emit TokensClaimed(_bidIds[i], bidOwner, bidTokensFilled);
            }
        }

        if (tokensFilled > 0) {
            Currency.wrap(address(TOKEN)).transfer(_owner, tokensFilled);
        }
    }

    function _internalClaimTokens(uint256 bidId) internal returns (address owner, uint256 tokensFilled) {
        Bid storage $bid = _getBid(bidId);
        if ($bid.exitedBlock == 0) revert BidNotExited();

        owner = $bid.owner;
        tokensFilled = $bid.tokensFilled;

        $bid.tokensFilled = 0;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function sweepCurrency() external onlyAfterAuctionIsOver ensureEndBlockIsCheckpointed {
        if (sweepCurrencyBlock != 0) revert CannotSweepCurrency();
        if (!_isGraduated()) revert NotGraduated();
        _sweepCurrency(_currencyRaised());
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function sweepUnsoldTokens() external onlyAfterAuctionIsOver ensureEndBlockIsCheckpointed {
        if (sweepUnsoldTokensBlock != 0) revert CannotSweepTokens();
        uint256 unsoldTokens;
        if (_isGraduated()) {
            unsoldTokens = TOTAL_SUPPLY_Q96.scaleUpToX7().sub($totalClearedQ96_X7).divUint256(FixedPoint96.Q96)
                .scaleDownToUint256();
        } else {
            unsoldTokens = TOTAL_SUPPLY;
        }
        _sweepUnsoldTokens(unsoldTokens);
    }

    // Getters
    /// @inheritdoc IHybridContinuousClearingAuction
    function claimBlock() external view returns (uint64) {
        return CLAIM_BLOCK;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function validationHook() external view returns (IValidationHook) {
        return VALIDATION_HOOK;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function currencyRaisedQ96_X7() external view returns (ValueX7) {
        return $currencyRaisedQ96_X7;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function sumCurrencyDemandAboveClearingQ96() external view returns (uint256) {
        return $sumCurrencyDemandAboveClearingQ96;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function totalClearedQ96_X7() external view returns (ValueX7) {
        return $totalClearedQ96_X7;
    }

    /// @inheritdoc IHybridContinuousClearingAuction
    function totalCleared() external view returns (uint256) {
        return $totalClearedQ96_X7.divUint256(FixedPoint96.Q96).scaleDownToUint256();
    }
}
