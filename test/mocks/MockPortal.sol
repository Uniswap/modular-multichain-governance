// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";

contract MockPortal is IPortal2 {
    uint256 public callCount;
    address public lastTo;
    uint256 public lastDepositValue;
    uint64 public lastGasLimit;
    bool public lastIsCreation;
    bytes public lastData;
    uint256 public lastValue;

    function depositTransaction(
        address to,
        uint256 value,
        uint64 gasLimit,
        bool isCreation,
        bytes memory data
    ) external payable {
        callCount += 1;
        lastTo = to;
        lastDepositValue = value;
        lastGasLimit = gasLimit;
        lastIsCreation = isCreation;
        lastData = data;
        lastValue = msg.value;
    }
}
