// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

interface IInbox {
    /// @notice Creates a retryable message to send to Arbitrum Orbit chain.
    /// @param to Call receiver on remote chain.
    /// @param l2CallValue Total value, in Ether, to send.
    /// @param maxSubmissionCost Max submission cost of call on remote chain.
    /// @param excessFeeRefundAddress Receiver of gas refund on remote chain.
    /// @param callValueRefundAddress Receiver of value refund on remote chain.
    /// @param gasLimit Gas limit for call on remote chain.
    /// @param maxFeePerGas Max fee per gas.
    /// @param data Data to send (forwarded directly).
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes memory data
    ) external payable returns (uint256);
}
