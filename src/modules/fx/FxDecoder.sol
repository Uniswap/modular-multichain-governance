// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";

/// @title Polygon Fx Decoder.
/// @notice Decodes message on Polygon from the FxRoot to FxChild system.
contract FxDecoder is IDecoder {
    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    /// @notice Polygon FxChild contract.
    address public immutable FX_CHILD;

    constructor(address senderHub, address receiverHub, address fxChild) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        FX_CHILD = fxChild;
    }

    /// @notice Decodes a message from Polygon's FxChild contract.
    /// @param caller Acount that called the Receiver Hub. MUST be the FxChild.
    /// @param data Data encoded in `processMessageFromRoot` from FxChild.
    /// @return Decoded call array.
    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());
        require(caller == FX_CHILD, InvalidReceiverHubCaller());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IBridgeCalls.processMessageFromRoot.selector, InvalidSelector());

        bytes calldata dataWithoutSelector = CalldataHandler.getCalldataWithoutSelector(data);
        (, address rootMessageSender, bytes memory encodedCalls) =
            abi.decode(dataWithoutSelector, (uint256, address, bytes));
        require(rootMessageSender == SENDER_HUB, NotFromSenderHub());

        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }
}
