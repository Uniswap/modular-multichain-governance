// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Arbitrum Bridge used by the fork tests.
interface IArbitrumBridge {
    /// @notice Logged for every message an Inbox enqueues, alongside the Inbox's own log.
    /// @param messageIndex Index of the message in the delayed inbox.
    /// @param beforeInboxAcc Delayed inbox accumulator before the message.
    /// @param inbox Inbox the message came through.
    /// @param kind Message kind, nine for a retryable ticket.
    /// @param sender Sender on L2, the L1 caller of the Inbox with the alias applied.
    /// @param messageDataHash Hash of the data the Inbox logged.
    /// @param baseFeeL1 L1 base fee the ticket's submission fee is priced at.
    /// @param timestamp L1 timestamp of the message.
    event MessageDelivered(
        uint256 indexed messageIndex,
        bytes32 indexed beforeInboxAcc,
        address inbox,
        uint8 kind,
        address sender,
        bytes32 messageDataHash,
        uint256 baseFeeL1,
        uint64 timestamp
    );

    /// @notice Count of messages enqueued so far, the index the next one gets.
    function delayedMessageCount() external view returns (uint256);
}
