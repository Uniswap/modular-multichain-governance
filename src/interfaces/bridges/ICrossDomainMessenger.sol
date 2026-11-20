// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the OP Stack CrossDomainMessenger shared by the L1CrossDomainMessenger on
///         Ethereum and the L2CrossDomainMessenger on the remote chain.
interface ICrossDomainMessenger {
    /// @notice Sends a message to the other chain's messenger, which calls `target` with it.
    /// @dev All of the call value is forwarded to `target` with the message.
    /// @param target Call receiver on the other chain.
    /// @param message Data to send (forwarded directly).
    /// @param minGasLimit Least gas `target` is called with on the other chain. The messenger adds
    ///        its own overhead on top when it buys gas for the message.
    function sendMessage(address target, bytes memory message, uint32 minGasLimit) external payable;

    /// @notice Sender, on the other chain, of the message the messenger is relaying.
    /// @dev Reverts unless called while a message is being relayed.
    function xDomainMessageSender() external view returns (address);
}
