// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Sender Hub.
/// @notice Receives an array of MultichainAction's from governance, dispatches encoders, and sends
///         multichain actions to bridges based on each action's target chain Id.
contract SenderHub is Owned(msg.sender), ISenderHub {
    /// @inheritdoc ISenderHub
    mapping(uint256 chainId => address) public encoders;

    /// @inheritdoc ISenderHub
    mapping(uint256 chainId => address) public receiverHubs;

    /// @inheritdoc ISenderHub
    function setEncoder(uint256 chainId, address encoder) public onlyOwner {
        address oldEncoder = encoders[chainId];
        encoders[chainId] = encoder;

        emit SetEncoder(chainId, oldEncoder, encoder);
    }

    /// @inheritdoc ISenderHub
    function setReceiverHub(uint256 chainId, address receiverHub) public onlyOwner {
        address oldReceiverHub = receiverHubs[chainId];
        receiverHubs[chainId] = receiverHub;

        emit SetReceiverHub(chainId, oldReceiverHub, receiverHub);
    }

    /// @inheritdoc ISenderHub
    function sendMultichainActions(MultichainAction[] calldata actions) public payable onlyOwner {
        for (uint256 i; i < actions.length; i++) {
            uint256 chainId = actions[i].chainId;
            address encoder = encoders[chainId];

            Call[] memory bridgeCalls = IEncoder(encoder).encode(actions[i], receiverHubs[chainId]);

            // The array may hold more than one bridge call if the encoder is a composite encoder.
            for (uint256 j; j < bridgeCalls.length; j++) {
                address bridge = bridgeCalls[j].target;

                (bool success,) = bridge.call{value: bridgeCalls[j].value}(bridgeCalls[j].data);

                require(success);

                emit SendMultichainAction(chainId, bridge, encoder);
            }
        }
    }
}
