// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HybridContinuousClearingAuction} from './HybridContinuousClearingAuction.sol';
import {HybridAuctionParameters} from './interfaces/IHybridContinuousClearingAuction.sol';
import {IHybridContinuousClearingAuctionFactory} from './interfaces/IHybridContinuousClearingAuctionFactory.sol';
import {IDistributionContract} from './interfaces/external/IDistributionContract.sol';
import {IDistributionStrategy} from './interfaces/external/IDistributionStrategy.sol';

import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';
import {ActionConstants} from 'v4-periphery/src/libraries/ActionConstants.sol';

/// @title HybridContinuousClearingAuctionFactory
/// @notice Factory contract for deploying Hybrid CCA instances
/// @dev Extends the standard CCA factory to support fixed-price phase parameters
/// @custom:security-contact security@uniswap.org
contract HybridContinuousClearingAuctionFactory is IHybridContinuousClearingAuctionFactory {
    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract distributionContract)
    {
        if (amount > type(uint128).max) revert InvalidTokenAmount(amount);

        HybridAuctionParameters memory parameters = abi.decode(configData, (HybridAuctionParameters));
        
        // If the tokensRecipient is address(1), set it to the msg.sender
        if (parameters.tokensRecipient == ActionConstants.MSG_SENDER) {
            parameters.tokensRecipient = msg.sender;
        }
        
        // If the fundsRecipient is address(1), set it to the msg.sender
        if (parameters.fundsRecipient == ActionConstants.MSG_SENDER) {
            parameters.fundsRecipient = msg.sender;
        }

        distributionContract = IDistributionContract(
            address(
                new HybridContinuousClearingAuction{salt: keccak256(abi.encode(msg.sender, salt))}(
                    token, uint128(amount), parameters
                )
            )
        );

        emit HybridAuctionCreated(
            address(distributionContract),
            token,
            uint128(amount),
            abi.encode(parameters)
        );
    }

    /// @inheritdoc IHybridContinuousClearingAuctionFactory
    function getAuctionAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address) {
        if (amount > type(uint128).max) revert InvalidTokenAmount(amount);
        
        HybridAuctionParameters memory parameters = abi.decode(configData, (HybridAuctionParameters));
        
        // If the tokensRecipient is address(1), set it to the sender
        if (parameters.tokensRecipient == ActionConstants.MSG_SENDER) {
            parameters.tokensRecipient = sender;
        }
        
        // If the fundsRecipient is address(1), set it to the sender
        if (parameters.fundsRecipient == ActionConstants.MSG_SENDER) {
            parameters.fundsRecipient = sender;
        }

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HybridContinuousClearingAuction).creationCode,
                abi.encode(token, uint128(amount), parameters)
            )
        );
        
        salt = keccak256(abi.encode(sender, salt));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }
}
