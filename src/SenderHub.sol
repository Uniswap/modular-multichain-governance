// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Sender Hub.
/// @notice Receives an array of MultichainAction's from governance, dispatches encoders, and sends
///         multichain actions to bridges based on each action's target chain Id.
contract SenderHub is Owned(msg.sender), ISenderHub {
    /// @inheritdoc ISenderHub
    mapping(uint256 chainId => address) public encoders;

    /// @inheritdoc ISenderHub
    mapping(uint256 chainId => address) public receiverHubs;

    function setEncoder(uint256 chainId, address encoder) public onlyOwner {
        encoders[chainId] = encoder;

        emit SetEncoder(chainId, encoder);
    }

    function setReceiverHub(uint256 chainId, address receiverHub) public onlyOwner {
        receiverHubs[chainId] = receiverHub;

        emit SetReceiverHub(chainId, receiverHub);
    }

    /// @inheritdoc ISenderHub
    function sendMultichainActions(MultichainAction[] calldata actions) public onlyOwner {
        for (uint256 i; i < actions.length; i++) {
            uint256 chainId = actions[i].chainId;
            address encoder = encoders[chainId];

            (address bridge, uint256 value, bytes memory data) =
                IEncoder(encoder).encode(actions[i]);

            (bool success,) = bridge.call{value: value}(data);

            require(success);

            emit SendMultichainAction(chainId, bridge, encoder);
        }
    }
}
