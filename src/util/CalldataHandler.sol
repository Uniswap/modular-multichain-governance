// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IDecoder} from "src/interfaces/modules/IDecoder.sol";

/// @title Calldata Processing Library.
/// @dev This is used for the `data` parameter for Decoder modules.
/// @dev The `data` parameter is actually the full calldata payload sent to the Receiver Hub.
library CalldataHandler {
    /// @dev Gets the selector for a given calldata payload.
    /// @param encodedCall An ABI-encoded call with a selector.
    /// @return The selector.
    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4) {
        require(encodedCall.length >= 4, IDecoder.CalldataTooShort());

        return bytes4(encodedCall[:4]);
    }

    /// @dev Gets the calldata without the selector for a given calldata payload.
    /// @dev Returns a calldata slice, ie an (offset, length) pair. Callers should keep it
    ///      in a `bytes calldata` variable.
    /// @param encodedCall An ABI-encoded call with a selector.
    /// @return Data without the selector.
    function getCalldataWithoutSelector(bytes calldata encodedCall)
        internal
        pure
        returns (bytes calldata)
    {
        require(encodedCall.length >= 4, IDecoder.CalldataTooShort());

        return encodedCall[4:];
    }
}
