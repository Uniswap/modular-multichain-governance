// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IInbox} from "src/interfaces/bridges/IInbox.sol";

contract MockInbox is IInbox {
    uint256 public callCount;
    address public lastTo;
    uint256 public lastL2CallValue;
    uint256 public lastMaxSubmissionCost;
    address public lastExcessFeeRefundAddress;
    address public lastCallValueRefundAddress;
    uint256 public lastGasLimit;
    uint256 public lastMaxFeePerGas;
    bytes public lastData;
    uint256 public lastValue;

    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes memory data
    ) external payable returns (uint256) {
        callCount += 1;
        lastTo = to;
        lastL2CallValue = l2CallValue;
        lastMaxSubmissionCost = maxSubmissionCost;
        lastExcessFeeRefundAddress = excessFeeRefundAddress;
        lastCallValueRefundAddress = callValueRefundAddress;
        lastGasLimit = gasLimit;
        lastMaxFeePerGas = maxFeePerGas;
        lastData = data;
        lastValue = msg.value;

        return callCount;
    }
}
