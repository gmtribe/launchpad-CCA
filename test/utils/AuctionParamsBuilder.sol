// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AuctionParameters} from '../../src/Base.sol';

library AuctionParamsBuilder {
    function init() internal pure returns (AuctionParameters memory) {
        return AuctionParameters({
            currency: address(0),
            token: address(0),
            totalSupply: 0,
            floorPrice: 0,
            tickSpacing: 0,
            validationHook: address(0),
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: 0,
            endBlock: 0,
            claimBlock: 0,
            auctionStepsData: new bytes(0)
        });
    }

    function withCurrency(AuctionParameters memory params, address currency) internal pure returns (AuctionParameters memory) {
        params.currency = currency;
        return params;
    }

    function withToken(AuctionParameters memory params, address token) internal pure returns (AuctionParameters memory) {
        params.token = token;
        return params;
    }

    function withTotalSupply(AuctionParameters memory params, uint256 totalSupply) internal pure returns (AuctionParameters memory) {
        params.totalSupply = totalSupply;
        return params;
    }

    function withFloorPrice(AuctionParameters memory params, uint256 floorPrice) internal pure returns (AuctionParameters memory) {
        params.floorPrice = floorPrice;
        return params;
    }

    function withTickSpacing(AuctionParameters memory params, uint256 tickSpacing) internal pure returns (AuctionParameters memory) {
        params.tickSpacing = tickSpacing;
        return params;
    }

    function withValidationHook(AuctionParameters memory params, address validationHook) internal pure returns (AuctionParameters memory) {
        params.validationHook = validationHook;
        return params;
    }

    function withTokensRecipient(AuctionParameters memory params, address tokensRecipient) internal pure returns (AuctionParameters memory) {
        params.tokensRecipient = tokensRecipient;
        return params;
    }

    function withFundsRecipient(AuctionParameters memory params, address fundsRecipient) internal pure returns (AuctionParameters memory) {
        params.fundsRecipient = fundsRecipient;
        return params;
    }

    function withStartBlock(AuctionParameters memory params, uint256 startBlock) internal pure returns (AuctionParameters memory) {
        params.startBlock = startBlock;
        return params;
    }

    function withEndBlock(AuctionParameters memory params, uint256 endBlock) internal pure returns (AuctionParameters memory) {
        params.endBlock = endBlock;
        return params;
    }

    function withClaimBlock(AuctionParameters memory params, uint256 claimBlock) internal pure returns (AuctionParameters memory) {
        params.claimBlock = claimBlock;
        return params;
    }

    function withAuctionStepsData(AuctionParameters memory params, bytes memory auctionStepsData) internal pure returns (AuctionParameters memory) {
        params.auctionStepsData = auctionStepsData;
        return params;
    }
}