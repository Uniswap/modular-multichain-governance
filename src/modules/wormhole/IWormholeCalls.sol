// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

/// @title Wormhole Call Virtual Interface
/// @notice Ensures every Wormhole message reaches the ReceiverHub behind a function selector
///         it can dispatch on.
interface IWormholeCalls {
    /// @notice Custom Wormhole call function.
    /// @dev Wormhole allows anyone to submit an encoded "Verifiable Message" which has no function
    ///      selector. We define this function to encapsulate that message such that the ReceiverHub
    ///      can dispatch the WormholeDecoder based on the selector rather than the caller or the
    ///      raw encoded data (which has no selector).
    /// @param encodedMessage VerifiableMessage as encoded in the Wormhole explorer.
    function wormholeCall(bytes memory encodedMessage) external;
}
