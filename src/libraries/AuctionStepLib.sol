// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AuctionStep} from '../Base.sol';

library AuctionStepLib {
    function get(bytes memory auctionStepsData, uint256 offset) internal pure returns (uint16 bps, uint48 blockDelta) {
        assembly {
            let packedValue := mload(add(add(auctionStepsData, 0x20), offset))
            packedValue := shr(192, packedValue)
            bps := shr(48, packedValue)
            blockDelta := and(packedValue, 0xFFFFFFFFFFFF)
        }
    }

    function resolvedSupply(AuctionStep memory step, uint256 totalSupply, uint256 totalCleared) internal pure returns (uint256) {
        return (totalSupply - totalCleared) * step.bps / (10_000 - step.bps);
    }
}