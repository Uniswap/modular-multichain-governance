// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {Call} from "src/types/Call.sol";
import {Constants} from "./Constants.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {Errors} from "./Errors.sol";

contract WormholeDecoder is IDecoder, Owned(msg.sender) {
    address public immutable SENDER_HUB;
    address public immutable RECEIVER_HUB;

    constructor(address senderHub, address receiverHub) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
    }

    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, Errors.CallerNotReceiverHub());
        require(Constants.removeAlias(caller) == SENDER_HUB, Errors.NotFromSenderHub());
        require(data.length > 4, Errors.InvalidCalldata());
        require(getSelector(data) == IBridgeCalls.arbitrumCall.selector, Errors.InvalidSelector());

        Call[] memory calls = getCalls(data);

        return calls;
    }

    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := calldataload(encodedCall.offset)
            selector := shl(0xe0, shr(0xe0, selector))
        }
    }

    function getCalls(bytes calldata encodedCall) internal pure returns (Call[] memory) {
        bytes memory data = new bytes(0);

        assembly ("memory-safe") {
            let src := add(encodedCall.offset, 0x04)
            let length := sub(encodedCall.offset, 0x04)
    
            data := mload(0x40)

            calldatacopy(src, data, length)

            mstore(0x40, add(data, length))
        }

        return abi.decode(data, (Call[]));
    }
}
