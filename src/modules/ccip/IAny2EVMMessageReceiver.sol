// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

/// @dev EVM Token Amount. Unused but required by a required data structure.
struct EVMTokenAmount {
    address token;
    uint256 amount;
}

/// @dev Data to receive from Ethereum on target chain.
/// @param messageId Unique identifier for the message.
/// @param sourceChainSelector Chainlink-defined selector for source chain (Always Ethereum).
/// @param sender Sender address, encoded via `abi.encode(address(sender))`.
/// @param data Data as forwarded from `EVM2AnyMessage`.
/// @param destTokenAmounts Always empty, no token transfers.
struct Any2EVMMessage {
    bytes32 messageId;
    uint64 sourceChainSelector;
    bytes sender;
    bytes data;
    EVMTokenAmount[] destTokenAmounts;
}

interface IAny2EVMMessageReceiver {
    /// @notice Called by the Router to deliver a message.
    /// @dev A failed message can be manually executed.
    /// @param message CCIP Message.
    /// @dev Note ensure you check the msg.sender is the Router.
    function ccipReceive(Any2EVMMessage calldata message) external;
}
