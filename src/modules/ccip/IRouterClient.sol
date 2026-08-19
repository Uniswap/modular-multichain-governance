// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

/// @dev EVM Token Amount. Unused but required by a required data structure.
struct EVMTokenAmount {
    address token;
    uint256 amount;
}

/// @dev Data to send from Ethereum to target chain.
/// @param receiver Receiver contact on target chain.
/// @param data Encoded data sent to receiver (this is wrapped in `Any2EVMMEssage`).
/// @param tokenAmounts Always empty, no token transfers.
/// @param feeToken Fee Token. Appears to always be chainlink token.
/// @param extraArgs Opaque encoded data. We use `GenericExtraArgsV2`.
struct EVM2AnyMessage {
    bytes receiver;
    bytes data;
    EVMTokenAmount[] tokenAmounts;
    address feeToken;
    bytes extraArgs;
}

interface IRouterClient {
    /// @notice Gets fee for a given chain and message.
    /// @param targetChainSelector Chainlink-defined target chain selector.
    /// @param message Message to send.
    function getFee(uint64 targetChainSelector, EVM2AnyMessage calldata message)
        external
        view
        returns (uint256);

    /// @notice Sends a message to a given chain.
    /// @param targetChainSelector Chainlink-defined target chain selector.
    /// @param message Message to send.
    /// @return The message id.
    function ccipSend(uint64 targetChainSelector, EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}
