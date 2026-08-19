// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IArbitrumCalls} from "src/modules/arbitrum-orbit/IArbitrumCalls.sol";
import {Call} from "src/types/Call.sol";

/// @title Arbitrum Orbit Inbox Decoder
/// @notice Decodes messages on Arbitrum Orbit chains.
contract InboxDecoder is IDecoder {
    /// @dev Arbitrum Orbit chain's Alias system.
    uint160 internal constant ARBITRUM_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    constructor(address senderHub, address receiverHub) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
    }

    /// @notice Decodes a message forwarded from an Arbitrum Orbit Inbox.
    /// @param caller Account that called the Receiver Hub. MUST be aliased Sender Hub.
    /// @param data Encoded `arbitrumCall` function.
    /// @return Decoded call array.
    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());
        require(removeAlias(caller) == SENDER_HUB, NotFromSenderHub());
        require(data.length >= 4, CalldataTooShort());

        bytes4 selector = bytes4(data[:4]);
        require(selector == IArbitrumCalls.arbitrumCall.selector, InvalidSelector());

        bytes calldata encodedCalls = data[4:];
        Call[] memory calls = abi.decode(encodedCalls, (Call[]));

        return calls;
    }

    /// @notice Removes the alias from an aliased address per Arbitrum Orbit system's rules.
    /// @dev Used in authenticating to the Sender Hub.
    function removeAlias(address l2Address) public pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - ARBITRUM_ALIAS);
        }
    }
}
