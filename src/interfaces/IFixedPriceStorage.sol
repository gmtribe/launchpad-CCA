// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFixedPriceStorage
/// @notice Interface for fixed price phase storage in V2 (FCFS allocation)
interface IFixedPriceStorage {
    /// @notice Error thrown when the fixed price is invalid (zero)
    error InvalidFixedPrice();
    
    /// @notice Error thrown when the fixed price exceeds the maximum bid price
    error FixedPriceAboveMaxBidPrice();
    
    /// @notice Error thrown when fixed phase allocation exceeds total supply
    error FixedPhaseAllocationExceedsTotalSupply();
    
    /// @notice Error thrown when no transition condition is set
    error NoTransitionConditionSet();
    
    /// @notice Error thrown when the fixed price end block is after the auction end
    error FixedPriceEndBlockAfterAuctionEnd();
    
    /// @notice Error thrown when attempting to transition when already transitioned
    error AlreadyTransitioned();
    
    /// @notice Error thrown when no fixed price tokens are available
    error NoFixedPriceTokensAvailable();

    /// @notice Emitted when the auction transitions from fixed price to CCA phase
    /// @param transitionBlock The block number when transition occurred
    event TransitionToCCA(uint64 transitionBlock);

    /// @notice Emitted when transition occurs with details
    /// @param transitionBlock The block number when transition occurred
    /// @param tokensSoldInFixedPhase Total tokens sold during fixed price phase
    /// @param fixedPrice The fixed price used
    event TransitionToCCAWithDetails(
        uint64 transitionBlock,
        uint128 tokensSoldInFixedPhase,
        uint256 fixedPrice
    );

    /// @notice Get the fixed price (in Q96 format)
    /// @return The fixed price
    function fixedPrice() external view returns (uint256);
    
    /// @notice Get the total token allocation for fixed price phase
    /// @return The number of tokens allocated to fixed price phase
    function fixedPhaseTokenAllocation() external view returns (uint128);
    
    /// @notice Get the block duration for fixed price phase
    /// @return The number of blocks for fixed price phase (0 if only using token allocation)
    function fixedPriceBlockDuration() external view returns (uint64);
    
    /// @notice Get the calculated end block for fixed price phase
    /// @return The block number when fixed price phase ends (based on duration)
    function fixedPriceEndBlock() external view returns (uint64);
    
    /// @notice Check if auction is in fixed price phase
    /// @return Whether the auction is currently in fixed price phase
    function isFixedPricePhase() external view returns (bool);
    
    /// @notice Get the block when transition occurred
    /// @return The block number when transition to CCA occurred (0 if not yet transitioned)
    function transitionBlock() external view returns (uint64);
    
    /// @notice Get total tokens sold during fixed price phase
    /// @return The number of tokens sold in fixed price phase
    function fixedPhaseSold() external view returns (uint128);
    
    /// @notice Get remaining tokens available in fixed price phase
    /// @return The number of tokens still available at fixed price
    function fixedPhaseRemainingTokens() external view returns (uint128);
}
