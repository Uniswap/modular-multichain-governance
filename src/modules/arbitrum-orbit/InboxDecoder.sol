// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {DecoderError} from "src/util/Errors.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";

contract InboxDecoder is IDecoder, Owned(msg.sender) {
    uint160 internal constant ARBITRUM_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    address public immutable SENDER_HUB;
    address public immutable RECEIVER_HUB;

    constructor(address senderHub, address receiverHub) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
    }

    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, DecoderError.CallerNotReceiverHub());
        require(removeAlias(caller) == SENDER_HUB, DecoderError.NotFromSenderHub());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IBridgeCalls.arbitrumCall.selector, DecoderError.InvalidSelector());

        bytes memory encodedCalls = CalldataHandler.getCalldataWithoutSelector(data);
        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }

    function removeAlias(address l2Address) public pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - ARBITRUM_ALIAS);
        }
    }
}
