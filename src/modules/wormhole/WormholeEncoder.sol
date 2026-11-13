// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Wormhole Encoder
/// @notice Encodes messages for the Wormhole bridge.
/// @dev While Wormhole defines their own custom chain Id's, we can avoid this complication by
///      simply encoding the target chain's EIP-155 chain Id into the payload to be checked on the
///      remote chain's Decoder module.
contract WormholeEncoder is IEncoder {
    /// @notice Wormhole-defined "Consistency Level".
    /// @dev We set to `1`, which means "Finalized on Ethereum".
    uint8 public constant CONSISTENCY_LEVEL = 1;

    /// @notice Wormhole core on Ethereum.
    address public immutable WORMHOLE;

    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Id of the most recently sent message.
    /// @dev A single counter is shared across all chains, so every message Id is globally unique.
    uint256 public messageId;

    constructor(address wormhole, address senderHub) {
        WORMHOLE = wormhole;
        SENDER_HUB = senderHub;
    }

    /// @notice Encodes a multichain action for the Wormhole core.
    /// @dev The local Wormhole core is the same for all remote networks.
    /// @dev The payload contains the message Id, the chain Id, and the calls to make.
    /// @dev The receiver hub argument is ignored since a published Wormhole message is not addressed
    ///      to anyone.
    /// @param multichainAction Action to send to the Receiver Hub on the remote chain.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(address, MultichainAction calldata multichainAction)
        public
        returns (Call[] memory)
    {
        require(msg.sender == SENDER_HUB, NotSenderHub());

        uint256 messageFee = IWormhole(WORMHOLE).messageFee();

        for (uint256 i; i < multichainAction.calls.length; i++) {
            require(multichainAction.calls[i].value == 0, InvalidCallValue());
        }

        uint256 id = ++messageId;

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: WORMHOLE,
            value: messageFee,
            data: abi.encodeCall(
                IWormhole.publishMessage,
                (
                    0,
                    abi.encode(id, multichainAction.chainId, multichainAction.calls),
                    CONSISTENCY_LEVEL
                )
            )
        });

        return bridgeCalls;
    }
}
