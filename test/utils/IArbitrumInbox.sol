// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Arbitrum Inbox used by the fork tests, beyond what the modules
///         themselves depend on (see `src/interfaces/bridges/IInbox.sol`).
interface IArbitrumInbox {
    /// @notice Thrown when the max submission cost is below the submission fee for the ticket's
    ///         calldata at the current L1 base fee.
    error InsufficientSubmissionCost(uint256 expected, uint256 actual);

    /// @notice Thrown when the gas limit or the max fee per gas is one. The Inbox reserves the
    ///         value to surface a ticket's parameters to gas estimation, it is never a valid input.
    error RetryableData(
        address from,
        address to,
        uint256 l2CallValue,
        uint256 deposit,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes data
    );

    /// @notice Thrown when the gas limit does not fit in 64 bits.
    error GasLimitTooLarge();

    /// @notice Thrown when the message, ticket header included, is larger than `maxDataSize`.
    error DataTooLarge(uint256 dataLength, uint256 maxDataLength);

    /// @notice Logged for every message, this is what the L2 derives the retryable ticket from.
    /// @param messageNum Index of the message in the bridge's delayed inbox.
    /// @param data For a retryable ticket, `abi.encodePacked` of `to`, `l2CallValue`, `msg.value`,
    ///        `maxSubmissionCost`, `excessFeeRefundAddress`, `callValueRefundAddress`, `gasLimit`,
    ///        `maxFeePerGas`, `data.length` (a word each) and `data`.
    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);

    /// @notice Bridge the Inbox enqueues messages on.
    function bridge() external view returns (address);

    /// @notice Largest message the Inbox accepts, in bytes.
    function maxDataSize() external view returns (uint256);

    /// @notice Submission fee of a ticket with `dataLength` bytes of calldata.
    /// @param baseFee L1 base fee to price at, zero for the current block's.
    function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee)
        external
        view
        returns (uint256);
}
