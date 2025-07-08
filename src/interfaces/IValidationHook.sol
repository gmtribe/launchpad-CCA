// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IValidationHook {
    function validate(uint256 blockNumber) external view;
}
