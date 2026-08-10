// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {Errors} from "src/modules/fx/Errors.sol";

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
        require(msg.sender == RECEIVER_HUB, Errors.CallerNotReceiverHub());
        require(getSelector(data) == IBridgeCalls.processMessageFromRoot.selector, Errors.InvalidSelector());

        (address rootMessageSender, Call[] memory calls) = getFxArguments(data);
        require(rootMessageSender == SENDER_HUB, Errors.NotFromSenderHub());

        return calls;
    }

    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := calldataload(encodedCall.offset)
            selector := shl(0xe0, shr(0xe0, selector))
        }
    }

    function getFxArguments(bytes calldata encodedCall) internal pure returns (
        address rootMessageSender,
        Call[] memory calls
    ) {
        bytes memory data;

        assembly ("memory-safe") {
            let rootMessageSenderPtr := add(encodedCall.offset, 0x24)
            
            rootMessageSender := calldataload(rootMessageSenderPtr)

            let dataSrc := calldataload(add(encodedCall.offset, 0x44))
            let dataLen := calldataload(dataSrc)

            data := mload(0x40)

            calldatacopy(dataSrc, data, dataLen)

            mstore(0x40, add(data, dataLen))
        }

        calls = abi.decode(data, (Call[]));

        return (rootMessageSender, calls);
    }
}
