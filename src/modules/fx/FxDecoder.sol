// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";
import {DecoderError} from "src/util/Errors.sol";

contract FxDecoder is IDecoder {
    address public immutable SENDER_HUB;
    address public immutable RECEIVER_HUB;
    address public immutable FX_CHILD;

    constructor(address senderHub, address receiverHub, address fxChild) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        FX_CHILD = fxChild;
    }

    function decode(address, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, DecoderError.CallerNotReceiverHub());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IBridgeCalls.processMessageFromRoot.selector, DecoderError.InvalidSelector());

        bytes memory dataWithoutSelector = CalldataHandler.getCalldataWithoutSelector(data);
        (, address rootMessageSender, bytes memory encodedCalls) = abi.decode(dataWithoutSelector, (uint256, address, bytes));
        require(rootMessageSender == SENDER_HUB, DecoderError.NotFromSenderHub());

        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }
}
