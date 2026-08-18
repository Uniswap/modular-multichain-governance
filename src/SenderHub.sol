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
        encoders[chainId] = encoder;

        emit SetEncoder(chainId, encoder);
    }

    /// @inheritdoc ISenderHub
    function setReceiverHub(uint256 chainId, address receiverHub) public onlyOwner {
        receiverHubs[chainId] = receiverHub;

        emit SetReceiverHub(chainId, receiverHub);
    }

    /// @inheritdoc ISenderHub
    function sendMultichainActions(MultichainAction[] calldata actions) public payable onlyOwner {
        for (uint256 i; i < actions.length; i++) {
            uint256 chainId = actions[i].chainId;
            address encoder = encoders[chainId];
            bytes32 actionHash = keccak256(abi.encode(actions[i].calls));

            // Actions can fail if i) the encoder has no code, ii) the encoder reverts,
            // iii) a bridge call fails, or iv) the encoder returns no bridge calls. A failing
            // action does not block other succeeding actions, and every action emits at least one
            // event. Recovery for a failed action is a follow-up proposal for that action alone.
            if (encoder.code.length == 0) {
                // Failure (i): the encoder has no code
                emit SendMultichainActionFailed(chainId, address(0x00), encoder, actionHash);

                continue;
            }

            try IEncoder(encoder).encode(actions[i], receiverHubs[chainId]) returns (
                Call[] memory bridgeCalls
            ) {
                // Failures (iii) and (iv): see within
                _sendBridgeCalls(chainId, encoder, actionHash, bridgeCalls);
            } catch {
                // Failure (ii): the encoder reverts
                emit SendMultichainActionFailed(chainId, address(0x00), encoder, actionHash);
            }
        }
    }

    /// @dev Makes the bridge calls for one encoded action and emits an outcome per call.
    ///      The array may hold more than one bridge call if the encoder is a composite encoder.
    /// @param chainId Chain the action targets.
    /// @param encoder Encoder module that produced the bridge calls.
    /// @param actionHash keccak256 of the action's abi-encoded calls.
    /// @param bridgeCalls Bridge calls returned by the encoder.
    function _sendBridgeCalls(
        uint256 chainId,
        address encoder,
        bytes32 actionHash,
        Call[] memory bridgeCalls
    ) internal {
        if (bridgeCalls.length == 0) {
            // Failure (iv): the encoder returned no bridge calls
            emit SendMultichainActionFailed(chainId, address(0x00), encoder, actionHash);
        }

        for (uint256 i; i < bridgeCalls.length; i++) {
            address bridge = bridgeCalls[i].target;

            bool success;

            if (bridge.code.length != 0) {
                (success,) = bridge.call{value: bridgeCalls[i].value}(bridgeCalls[i].data);
            }

            if (success) {
                emit SendMultichainAction(chainId, bridge, encoder, actionHash);
            } else {
                // Failure (iii): the bridge has no code or the bridge call fails
                emit SendMultichainActionFailed(chainId, bridge, encoder, actionHash);
            }
        }
    }
}
