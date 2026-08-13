// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

/// @title Bridge Call Virtual Interface
/// @notice This encapsulates some functions used in message passing between Encoder and Decoder
///     modules. Some bridge architectures forward raw data from the sending contract while others
///     use a custom function. This ensures that every message is prefixed with *some* function
///     selector which can be used to dispatch the appropriate Decoder. Each function's
///     documentation explains the respective context.
interface IBridgeCalls {
    /// @notice Custom Wormhole call function.
    /// @dev Wormhole allows anyone to submit an encoded "Verifiable Message" which has no function
    ///      selector. We define this function to encapsulate that message such that the ReceiverHub
    ///      can dispatch the WormholeDecoder based on the selector rather than the caller or the
    ///      raw encoded data (which has no selector).
    /// @param encodedMessage VerifiableMessage as encoded in the Wormhole explorer.
    function wormholeCall(bytes memory encodedMessage) external;

    /// @notice Custom Arbitrum Orbit call function.
    /// @dev Arbitrum Orbit chains forward the `data` parameter from its Inbox call directly. We
    ///      define this function to encapsulate the call array such that the ReceiverHub can
    ///      dispatch the InboxDecoder based on the selector rather than the call array (which has
    ///      no selector).
    function arbitrumCall(Call[] memory calls) external;

    /// @notice Polygon Fx Child call function.
    /// @dev Polygon calls this function via its FxChild contract on Polygon. The FxChild calls the
    ///      ReceiverHub with this function so it can dispatch the FxDecoder.
    function processMessageFromRoot(uint256 stateId, address rootMessageSender, bytes calldata data)
        external;
}
