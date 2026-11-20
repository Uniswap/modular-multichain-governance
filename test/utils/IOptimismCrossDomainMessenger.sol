// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed L1CrossDomainMessenger and L2CrossDomainMessenger used by the
///         fork tests, beyond what the modules themselves depend on (see
///         `src/interfaces/bridges/ICrossDomainMessenger.sol`).
interface IOptimismCrossDomainMessenger {
    /// @notice Logged by the receiving messenger when a message's call succeeds.
    /// @param msgHash Hash of the message, the hash of its `relayMessage` calldata.
    event RelayedMessage(bytes32 indexed msgHash);

    /// @notice Logged by the receiving messenger when a message's call fails, the message can
    ///         then be relayed again.
    /// @param msgHash Hash of the message, the hash of its `relayMessage` calldata.
    event FailedRelayedMessage(bytes32 indexed msgHash);

    /// @notice Relays a message. The other chain's messenger does so when the message arrives,
    ///         after which anyone can for a message that failed, without value.
    /// @param nonce Nonce the sending messenger gave the message.
    /// @param sender Account that sent the message on the other chain.
    /// @param target Call receiver.
    /// @param value Ether sent with the message.
    /// @param minGasLimit Least gas `target` is called with.
    /// @param message Data `target` is called with.
    function relayMessage(
        uint256 nonce,
        address sender,
        address target,
        uint256 value,
        uint256 minGasLimit,
        bytes calldata message
    ) external payable;

    /// @notice Gas the sending messenger buys for a message, `minGasLimit` and the receiving
    ///         messenger's overhead.
    function baseGas(bytes calldata message, uint32 minGasLimit) external pure returns (uint64);

    /// @notice Nonce the next message sent is given, with the message version in its top bytes.
    function messageNonce() external view returns (uint256);

    /// @notice True for a message whose call has failed at least once, which stays true after a
    ///         later relay succeeds.
    function failedMessages(bytes32 msgHash) external view returns (bool);

    /// @notice True for a message whose call has succeeded, which cannot be relayed again.
    function successfulMessages(bytes32 msgHash) external view returns (bool);
}
