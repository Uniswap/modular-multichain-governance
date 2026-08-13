// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

interface IDecoder {
    /// @notice Decodes a bridge call into an array of calls to run by the ReceiverHub.
    /// @dev We provide the ReceiverHub's calldata as an argument to this function rather than
    ///      forward the calldata directly to ensure decoders all have the same interface.
    /// @param caller The address that called the ReceiverHub.
    /// @param data The full calldata received by the ReceiverHub.
    /// @return Call list to run from ReceiverHub.
    function decode(address caller, bytes calldata data) external returns (Call[] memory);
}
