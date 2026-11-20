// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {Call} from "src/types/Call.sol";

/// @title OP Stack L1CrossDomainMessenger Decoder
/// @notice Decodes messages on OP Stack chains sent through the L1CrossDomainMessenger.
/// @dev The L2CrossDomainMessenger calls the Receiver Hub both when a message first arrives and
///      when anyone relays a failed one again, so both are authenticated the same way here. A
///      failed message never expires on the messenger.
contract L1CrossDomainMessengerDecoder is IDecoder {
    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    /// @notice L2CrossDomainMessenger on local chain.
    address public immutable L2_MESSENGER;

    constructor(address senderHub, address receiverHub, address l2Messenger) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        L2_MESSENGER = l2Messenger;
    }

    /// @notice Decodes a message relayed by the L2CrossDomainMessenger.
    /// @dev The messenger does not alias the sender, it reports the account that called the
    ///      L1CrossDomainMessenger as is.
    /// @param caller Account that called the Receiver Hub. MUST be the L2CrossDomainMessenger.
    /// @param data Encoded `crossDomainMessengerCall` function.
    /// @return Decoded call array.
    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());
        require(caller == L2_MESSENGER, InvalidReceiverHubCaller());
        require(
            ICrossDomainMessenger(L2_MESSENGER).xDomainMessageSender() == SENDER_HUB,
            NotFromSenderHub()
        );
        require(data.length >= 4, CalldataTooShort());

        bytes4 selector = bytes4(data[:4]);
        require(
            selector == ICrossDomainMessengerCalls.crossDomainMessengerCall.selector,
            InvalidSelector()
        );

        bytes calldata encodedCalls = data[4:];
        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }
}
