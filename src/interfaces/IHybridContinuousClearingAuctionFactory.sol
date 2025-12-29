// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionStrategy} from './external/IDistributionStrategy.sol';

/// @title IHybridContinuousClearingAuctionFactory
/// @notice Interface for the Hybrid CCA factory contract
interface IHybridContinuousClearingAuctionFactory is IDistributionStrategy {
    /// @notice Error thrown when the token amount is invalid
    /// @param amount The invalid amount
    error InvalidTokenAmount(uint256 amount);

    /// @notice Emitted when a hybrid auction is created
    /// @param auction The address of the deployed auction contract
    /// @param token The address of the token being auctioned
    /// @param amount The total amount of tokens to sell
    /// @param configData The encoded configuration data for the auction
    event HybridAuctionCreated(
        address indexed auction,
        address indexed token,
        uint256 amount,
        bytes configData
    );

    /// @notice Compute the deterministic address of a hybrid auction contract
    /// @param token The address of the token to be distributed
    /// @param amount The amount of tokens intended for distribution
    /// @param configData The encoded HybridAuctionParameters
    /// @param salt The salt to use for the deterministic deployment
    /// @param sender The address that will call initializeDistribution
    /// @return The computed address of the auction contract
    function getAuctionAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address);
}
