// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridContinuousClearingAuction} from '../../src/HybridContinuousClearingAuction.sol';
import {HybridAuctionParameters} from '../../src/interfaces/IHybridContinuousClearingAuction.sol';
import {Bid} from '../../src/libraries/BidLib.sol';
import {Checkpoint} from '../../src/libraries/CheckpointLib.sol';
import {FixedPoint96} from '../../src/libraries/FixedPoint96.sol';

/// @notice Mock contract for testing internal functions
contract MockHybridAuction is HybridContinuousClearingAuction {
    
    constructor(
        address _token,
        uint128 _totalSupply,
        HybridAuctionParameters memory _parameters
    ) HybridContinuousClearingAuction(_token, _totalSupply, _parameters) {}

    // ============================================
    // Expose Internal Functions
    // ============================================

    /// @notice Expose _checkTransitionConditions
    function exposed_checkTransitionConditions() external view returns (bool) {
        (bool tokenAllocationMet, bool blockDurationMet) = _checkTransitionConditions(uint64(block.number));
        return tokenAllocationMet || blockDurationMet;
    }

    /// @notice Expose _executeTransition
    function exposed_executeTransition() external {
        uint64 transitionBlock = uint64(block.number);
        _executeTransition(transitionBlock);
    }

    /// @notice Expose _initializeCCASupply
    function exposed_initializeCCASupply(uint128 _supply) external {
        _initializeCCASupply(_supply);
    }

    /// @notice Expose _initializeCCAPhase
    function exposed_initializeCCAPhase(uint64 _startBlock) external {
        _initializeCCAPhase(_startBlock);
    }

    /// @notice Expose _recordFixedPhaseSale
    function exposed_recordFixedPhaseSale(uint128 _amount) external {
        _recordFixedPhaseSale(_amount);
    }

    /// @notice Expose _getFixedPhaseRemainingTokens
    function exposed_getFixedPhaseRemainingTokens() external view returns (uint128) {
        return _getFixedPhaseRemainingTokens();
    }

    /// @notice Expose _processFixedPriceOrder
    /// @dev Returns tokensFilled, currencySpent, and refund
    function exposed_processFixedPriceOrder(uint128 _currencyAmount) 
        external 
        returns (uint128 tokensFilled, uint128 currencySpent, uint128 refund) 
    {
        // Call the internal function which returns (bidId, tokensFilled)
        (, tokensFilled) = _processFixedPriceOrder(_currencyAmount, address(this));
        
        // Calculate currency spent and refund
        currencySpent = uint128((uint256(tokensFilled) * FIXED_PRICE) / FixedPoint96.Q96);
        refund = _currencyAmount - currencySpent;
        
        return (tokensFilled, currencySpent, refund);
    }

    // ============================================
    // Expose Storage Setters for Testing
    // ============================================

    /// @notice Set fixedPhaseSold for testing
    function exposed_setFixedPhaseSold(uint128 _amount) external {
        $_fixedPhaseSold = _amount;
    }

    // ============================================
    // Test Modifiers Exposure
    // ============================================

    /// @notice Test onlyActiveAuction modifier
    function modifier_onlyActiveAuction() external view onlyActiveAuction {
        // No-op, just testing modifier
    }

    /// @notice Test onlyAfterAuctionIsOver modifier
    function modifier_onlyAfterAuctionIsOver() external view onlyAfterAuctionIsOver {
        // No-op, just testing modifier
    }
}
