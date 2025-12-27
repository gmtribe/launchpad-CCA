// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFixedPriceStorage} from './interfaces/IFixedPriceStorage.sol';
import {ConstantsLib} from './libraries/ConstantsLib.sol';

/// @title FixedPriceStorage V2
/// @notice Abstract contract for managing fixed price phase with simple FCFS allocation (no continuous clearing)
/// @dev In this version, fixed price orders are filled immediately on a first-come-first-served basis
abstract contract FixedPriceStorage is IFixedPriceStorage {
    /// @notice The fixed price during the initial phase (in Q96 format)
    uint256 internal FIXED_PRICE;
    
    /// @notice Number of blocks from START_BLOCK after which to transition to CCA
    /// @dev If set to 0, only token allocation threshold is used
    uint64 internal FIXED_PRICE_BLOCK_DURATION;
    
    /// @notice The calculated end block for fixed price phase based on block duration
    uint64 internal FIXED_PRICE_END_BLOCK;
    
    /// @notice Total tokens allocated to fixed price phase (not in Q96)
    /// @dev Once this amount is sold, transition to CCA occurs
    uint128 internal FIXED_PHASE_TOKEN_ALLOCATION;

    /// @notice Whether the auction is currently in fixed price phase
    bool internal $_isFixedPricePhase;
    
    /// @notice Block number when transition from fixed price to CCA occurred
    uint64 internal $_transitionBlock;
    
    /// @notice Total tokens sold during fixed price phase
    /// @dev This tracks actual tokens sold, not MPS
    uint128 internal $_fixedPhaseSold;

    /// @notice Initialize the fixed price storage
    /// @dev Called from child contract constructor to avoid stack depth issues
    function _initializeFixedPriceStorage(
        uint256 _fixedPrice,
        uint128 _fixedPhaseTokenAllocation,
        uint64 _fixedPriceBlockDuration,
        uint64 _startBlock,
        uint64 _endBlock,
        uint256 _maxBidPrice,
        uint128 _totalSupply
    ) internal {
        // Check if this is a pure CCA auction (no fixed price phase)
        bool isPureCCA = (_fixedPhaseTokenAllocation == 0 && _fixedPriceBlockDuration == 0);
        
        if (isPureCCA) {
            // Pure CCA mode: fixed price phase disabled
            FIXED_PRICE = _fixedPrice;
            FIXED_PHASE_TOKEN_ALLOCATION = 0;
            FIXED_PRICE_BLOCK_DURATION = 0;
            FIXED_PRICE_END_BLOCK = _startBlock;
            
            // Start directly in CCA phase
            $_isFixedPricePhase = false;
            $_transitionBlock = _startBlock;
            $_fixedPhaseSold = 0;
        } else {
            // Hybrid mode: validate parameters
            
            if (_fixedPrice == 0) revert InvalidFixedPrice();
            if (_fixedPrice > _maxBidPrice) revert FixedPriceAboveMaxBidPrice();
            
            // Token allocation cannot exceed total supply
            if (_fixedPhaseTokenAllocation > _totalSupply) {
                revert FixedPhaseAllocationExceedsTotalSupply();
            }
            
            // Must have at least one transition condition
            if (_fixedPhaseTokenAllocation == 0 && _fixedPriceBlockDuration == 0) {
                revert NoTransitionConditionSet();
            }

            FIXED_PRICE = _fixedPrice;
            FIXED_PHASE_TOKEN_ALLOCATION = _fixedPhaseTokenAllocation;
            FIXED_PRICE_BLOCK_DURATION = _fixedPriceBlockDuration;

            // Calculate fixed price end block
            if (_fixedPriceBlockDuration > 0) {
                uint64 calculatedEndBlock = _startBlock + _fixedPriceBlockDuration;
                if (calculatedEndBlock > _endBlock) {
                    revert FixedPriceEndBlockAfterAuctionEnd();
                }
                FIXED_PRICE_END_BLOCK = calculatedEndBlock;
            } else {
                FIXED_PRICE_END_BLOCK = _endBlock;
            }

            // Initialize in fixed price phase
            $_isFixedPricePhase = true;
            $_fixedPhaseSold = 0;
        }
    }

    /// @notice Check if transition conditions are met
    /// @dev Checks both token allocation and block duration conditions
    /// @param currentBlock The current block number
    /// @return tokenAllocationMet Whether all fixed price tokens have been sold
    /// @return blockDurationMet Whether the block duration has been reached
    function _checkTransitionConditions(uint64 currentBlock)
        internal
        view
        returns (bool tokenAllocationMet, bool blockDurationMet)
    {
        // Check if all allocated tokens have been sold
        tokenAllocationMet = (FIXED_PHASE_TOKEN_ALLOCATION > 0) && 
                            ($_fixedPhaseSold >= FIXED_PHASE_TOKEN_ALLOCATION);
        
        // Check if block duration has been reached
        blockDurationMet = (FIXED_PRICE_BLOCK_DURATION > 0) && 
                          (currentBlock >= FIXED_PRICE_END_BLOCK);
    }

    /// @notice Execute transition from fixed price to CCA
    /// @param blockNumber The block number when transition occurs
    function _executeTransition(uint64 blockNumber) internal virtual {
        if (!$_isFixedPricePhase) revert AlreadyTransitioned();
        
        $_isFixedPricePhase = false;
        $_transitionBlock = blockNumber;
        
        emit TransitionToCCA(blockNumber);
    }

    /// @notice Record tokens sold in fixed price phase
    /// @param amount The amount of tokens sold
    function _recordFixedPhaseSale(uint128 amount) internal {
        $_fixedPhaseSold += amount;
    }

    /// @notice Get remaining tokens available in fixed price phase
    /// @return The number of tokens still available at fixed price
    function _getFixedPhaseRemainingTokens() internal view returns (uint128) {
        if (!$_isFixedPricePhase) return 0;
        if (FIXED_PHASE_TOKEN_ALLOCATION == 0) return 0;
        
        return FIXED_PHASE_TOKEN_ALLOCATION - $_fixedPhaseSold;
    }

    /// @notice Check if auction is in fixed price phase
    function _isFixedPricePhase() internal view returns (bool) {
        return $_isFixedPricePhase;
    }

    // Getters
    /// @inheritdoc IFixedPriceStorage
    function fixedPrice() external view returns (uint256) {
        return FIXED_PRICE;
    }

    /// @inheritdoc IFixedPriceStorage
    function fixedPhaseTokenAllocation() external view returns (uint128) {
        return FIXED_PHASE_TOKEN_ALLOCATION;
    }

    /// @inheritdoc IFixedPriceStorage
    function fixedPriceBlockDuration() external view returns (uint64) {
        return FIXED_PRICE_BLOCK_DURATION;
    }

    /// @inheritdoc IFixedPriceStorage
    function fixedPriceEndBlock() external view returns (uint64) {
        return FIXED_PRICE_END_BLOCK;
    }

    /// @inheritdoc IFixedPriceStorage
    function isFixedPricePhase() external view returns (bool) {
        return $_isFixedPricePhase;
    }

    /// @inheritdoc IFixedPriceStorage
    function transitionBlock() external view returns (uint64) {
        return $_transitionBlock;
    }

    /// @inheritdoc IFixedPriceStorage
    function fixedPhaseSold() external view returns (uint128) {
        return $_fixedPhaseSold;
    }

    /// @inheritdoc IFixedPriceStorage
    function fixedPhaseRemainingTokens() external view returns (uint128) {
        return _getFixedPhaseRemainingTokens();
    }
}
