// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

/// @title Polygon Fx Message Processor
interface IFxMessageProcessor {
    /// @notice Polygon Fx Child call function.
    /// @dev Polygon calls this function via its FxChild contract on Polygon. The FxChild calls the
    ///      ReceiverHub with this function so it can dispatch the FxDecoder.
    /// @param stateId Polygon state sync id.
    /// @param rootMessageSender Sender of the message on Ethereum.
    /// @param data Data sent from Ethereum.
    function processMessageFromRoot(uint256 stateId, address rootMessageSender, bytes calldata data)
        external;
}
