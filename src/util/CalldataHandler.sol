// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {DecoderError} from "src/util/Errors.sol";

/// @title Calldata Processing Library.
/// @dev This is used for the `data` parameter for Decoder modules.
/// @dev The `data` parameter is actually the full calldata payload sent to the Receiver Hub.
library CalldataHandler {
    /// @dev Gets the selector for a given calldata payload.
    /// @param encodedCall An ABI-encoded call with a selector.
    /// @return The selector.
    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4) {
        require(encodedCall.length >= 4, DecoderError.CalldataTooShort());

        bytes4 selector;

        assembly ("memory-safe") {
            // Loads the first word of the `encodedCall`.
            //
            selector := calldataload(encodedCall.offset)

            // Bit-shifts the first word (right, then left), clipping the right-most 224 bits.
            //
            // This leaves only the upper 32 bits (4 bytes) of the first word of the encoded call.
            //
            selector := shl(0xe0, shr(0xe0, selector))
        }

        return selector;
    }

    /// @dev Gets the calldata without the selector for a given calldata payload.
    /// @param encodedCall An ABI-encoded call with a selector.
    /// @return Data without the selector.
    function getCalldataWithoutSelector(bytes calldata encodedCall) internal pure returns (bytes memory) {
        require(encodedCall.length >= 4, DecoderError.CalldataTooShort());

        bytes memory data;

        assembly ("memory-safe") {
            // Loads the free memory pointer, as stored in `0x40` by Solidity.
            //
            // Safe to use, so long as the memory allocation is finalized.
            //
            let ptr := mload(0x40)

            // Assigns the `data` variable to the start of free memory.
            //
            data := ptr

            // Writes the length of the call to the start of free memory.
            //
            mstore(data, encodedCall.length)

            // Assigns the `source` to be the encoded call's offset plus 4 bytes (the size of the
            // selector).
            //
            let source := add(encodedCall.offset, 0x04)

            // Assigns the `destination` to be the first word after the start of free memory.
            //
            let destination := add(data, 0x20)

            // Assigns the `length` to be encoded calls' length minus 4 bytes (the size of the
            // selector).
            let length := sub(encodedCall.length, 0x04)

            // Copies the encoded call to memory wihtout the selector.
            //
            calldatacopy(source, destination, length)

            // Writes the new free memory pointer to memory slot `0x40` per Solidity.
            //
            // New memory size: `ptr` + `length` + 32
            //
            // Note: The "+ 32" is for the 32 bytes used to store the `data` length.
            //
            // Finalizes the new memory allocation.
            //
            mstore(0x40, add(ptr, add(length, 0x20)))
        }

        return data;
    }
}
