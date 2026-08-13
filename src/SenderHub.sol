// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
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
    function setEncoders(uint256[] calldata chainIds, address[] calldata encoderModules) public onlyOwner {
        require(chainIds.length == encoderModules.length);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            address encoder = encoderModules[i];

            encoders[chainId] = encoder;

            emit SetEncoder(chainId, encoder);
        }    
    }

    /// @inheritdoc ISenderHub
    function setReceiverHubs(uint256[] calldata chainIds, address[] calldata recvHubs) public onlyOwner {
        require(chainIds.length == recvHubs.length);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            address receiverHub = recvHubs[i];

            receiverHubs[chainId] = receiverHub;

            emit SetReceiverHub(chainId, receiverHub);
        }
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
