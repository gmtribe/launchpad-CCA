// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStepStorage} from './interfaces/IStepStorage.sol';
import {ConstantsLib} from './libraries/ConstantsLib.sol';
import {AuctionStep, StepLib} from './libraries/StepLib.sol';
import {SSTORE2} from 'solady/utils/SSTORE2.sol';

/// @title StepStorage
/// @notice Abstract contract to store and read information about the auction issuance schedule
abstract contract StepStorage is IStepStorage {
    using StepLib for *;
    using SSTORE2 for *;

    /// @notice The block at which the auction starts
    uint64 internal immutable START_BLOCK;
    /// @notice The block at which the auction ends
    uint64 internal END_BLOCK;
    /// @notice Cached length of the auction steps data provided in the constructor
    uint256 internal immutable _LENGTH;

    /// @notice The block at which the CCA phase starts (set during transition for hybrid auctions)
    /// @dev For pure CCA auctions, this equals START_BLOCK
    ///      For hybrid auctions, this is set during transition from fixed price to CCA
    uint64 internal CCA_START_BLOCK;

    /// @notice The address pointer to the contract deployed by SSTORE2
    address private immutable $_pointer;
    /// @notice The word offset of the last read step in `auctionStepsData` bytes
    uint256 private $_offset;
    /// @notice The current active auction step
    AuctionStep internal $step;

    constructor(bytes memory _auctionStepsData, uint64 _startBlock, uint64 _endBlock) {
        if (_startBlock >= _endBlock) revert InvalidEndBlock();
        START_BLOCK = _startBlock;
        END_BLOCK = _endBlock;
        _LENGTH = _auctionStepsData.length;

        address _pointer = _auctionStepsData.write();
        _validate(_pointer);
        $_pointer = _pointer;

        // _advanceStep(); kept to running original CCA test 

        // Note: _advanceStep() is NOT called here anymore
        // For pure CCA: called in _initializeCCAPhase() 
        // For hybrid: called during transition
    }

    /// @notice Initialize CCA phase parameters
    /// @dev Called from child contract for pure CCA mode or during transition for hybrid mode
    /// @param ccaTransitionBlock The block when CCA phase begins
    function _initializeCCAPhase(uint64 ccaTransitionBlock) internal {
        if (CCA_START_BLOCK != 0) revert CCAAlreadyInitialized();
        
        CCA_START_BLOCK = ccaTransitionBlock;
        _updateEndBlock(ccaTransitionBlock);
        // Initialize the first step
        _advanceStep();
    }

    /// @notice Calculate the total duration (in blocks) of all CCA steps
    /// @return Total number of blocks across all steps
    function _calculateStepsDuration() internal view returns (uint64) {
        bytes memory _auctionStepsData = $_pointer.read();
        uint64 totalBlocks = 0;
        
        for (uint256 i = 0; i < _LENGTH; i += StepLib.UINT64_SIZE) {
            (, uint40 blockDelta) = _auctionStepsData.get(i);
            totalBlocks += blockDelta;
        }
        
        return totalBlocks;
    }

    /// @notice Update END_BLOCK based on actual CCA start time
    /// @dev Called during transition to adjust END_BLOCK for early fixed phase completion
    /// @param ccaTransitionBlock The block when CCA phase actually starts
    function _updateEndBlock(uint64 ccaTransitionBlock) internal {
        uint64 stepsDuration = _calculateStepsDuration();
        END_BLOCK = ccaTransitionBlock + stepsDuration;
        emit EndBlockUpdated(END_BLOCK);
    }

    /// @notice Validate the data provided in the constructor
    /// @dev Checks that the contract was correctly deployed by SSTORE2 and that the total mps and blocks are valid
    function _validate(address _pointer) internal view {
        bytes memory _auctionStepsData = _pointer.read();
        if (
            _auctionStepsData.length == 0 || _auctionStepsData.length % StepLib.UINT64_SIZE != 0
                || _auctionStepsData.length != _LENGTH
        ) revert InvalidAuctionDataLength();

        // Loop through the auction steps data and check if the mps is valid
        uint256 sumMps = 0;
        uint64 sumBlockDelta = 0;
        for (uint256 i = 0; i < _LENGTH; i += StepLib.UINT64_SIZE) {
            (uint24 mps, uint40 blockDelta) = _auctionStepsData.get(i);
            // Prevent the block delta from being set to zero
            if (blockDelta == 0) revert StepBlockDeltaCannotBeZero();
            sumMps += mps * blockDelta;
            sumBlockDelta += blockDelta;
        }
        if (sumMps != ConstantsLib.MPS) revert InvalidStepDataMps(sumMps, ConstantsLib.MPS);
        // uint64 calculatedEndBlock = START_BLOCK + sumBlockDelta;
        // if (calculatedEndBlock != END_BLOCK) revert InvalidEndBlockGivenStepData(calculatedEndBlock, END_BLOCK);
    }

    /// @notice Advance the current auction step
    /// @dev This function is called on every new bid if the current step is complete
    function _advanceStep() internal returns (AuctionStep memory) {
        if ($_offset >= _LENGTH) revert AuctionIsOver();

        bytes8 _auctionStep = bytes8($_pointer.read($_offset, $_offset + StepLib.UINT64_SIZE));
        (uint24 mps, uint40 blockDelta) = _auctionStep.parse();

        uint64 _startBlock = $step.endBlock;
        if (_startBlock == 0) _startBlock = CCA_START_BLOCK;
        // if (_startBlock == 0) _startBlock = CCA_START_BLOCK != 0 ? CCA_START_BLOCK : START_BLOCK; // this condition is just to pass original test case
        uint64 _endBlock = _startBlock + uint64(blockDelta);

        $step = AuctionStep({startBlock: _startBlock, endBlock: _endBlock, mps: mps});

        $_offset += StepLib.UINT64_SIZE;

        emit AuctionStepRecorded(_startBlock, _endBlock, mps);
        return $step;
    }

    /// @inheritdoc IStepStorage
    function step() external view returns (AuctionStep memory) {
        return $step;
    }

    // Getters
    /// @inheritdoc IStepStorage
    function startBlock() external view returns (uint64) {
        return START_BLOCK;
    }

    /// @inheritdoc IStepStorage
    function endBlock() external view returns (uint64) {
        return END_BLOCK;
    }

    /// @inheritdoc IStepStorage
    function pointer() external view returns (address) {
        return $_pointer;
    }
    
    /// @notice Get the CCA phase start block
    /// @return The block at which CCA phase begins
    function ccaStartBlock() external view returns (uint64) {
        return CCA_START_BLOCK;
    }
}
