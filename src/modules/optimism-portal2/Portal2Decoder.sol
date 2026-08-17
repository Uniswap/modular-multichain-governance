// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";
import {DecoderError} from "src/util/Errors.sol";

contract Portal2Decoder is IDecoder {
    /// @dev Op Stack chain's Alias system.
    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    constructor(address senderHub, address receiverHub) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
    }

    /// @notice Decodes a message forwarded from an OP Stack Portal.
    /// @param caller Account that called the Receiver Hub. MUST be aliased Sender Hub.
    /// @param data Encoded `portal2Call` function.
    /// @return Decoded call array.
    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, DecoderError.CallerNotReceiverHub());
        require(removeAlias(caller) == SENDER_HUB, DecoderError.NotFromSenderHub());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IBridgeCalls.portal2Call.selector, DecoderError.InvalidSelector());

        bytes memory encodedCalls = CalldataHandler.getCalldataWithoutSelector(data);
        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }

    /// @notice Removes the alias from an aliased address per OP Stack system's rules.
    /// @dev Used in authenticating to the Sender Hub.
    function removeAlias(address l2Address) public pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - OP_STACK_ALIAS);
        }
    }
}
