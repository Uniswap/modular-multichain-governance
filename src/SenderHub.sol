// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {EncoderSet} from "src/types/EncoderSet.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract SenderHub is Owned(msg.sender) {
    event SetEncoder(uint256 indexed chainId, bytes32 indexed bridgeId, address indexed module);
    event SendMultichainAction(
        uint256 indexed chainId, address indexed bridge, address indexed encoder, bytes32 hash
    );

    mapping(uint256 chainId => mapping(bytes32 bridgeId => address)) encoders;

    function setEncoders(EncoderSet[] memory encoderSets) external onlyOwner {
        for (uint256 i; i < encoderSets.length; i++) {
            uint256 chainId = encoderSets[i].chainId;
            bytes32 bridgeId = encoderSets[i].bridgeId;
            address encoder = encoderSets[i].encoder;

            encoders[chainId][bridgeId] = encoder;

            emit SetEncoder(chainId, bridgeId, encoder);
        }
    }

    function sendMultichainActions(MultichainAction[] calldata actions) external onlyOwner {
        for (uint256 i; i < actions.length; i++) {
            uint256 chainId = actions[i].chainId;
            bytes32 bridgeId = actions[i].bridgeId;
            address encoder = encoders[chainId][bridgeId];

            bytes32 hash = keccak256(abi.encode(actions[i].calls));

            require(encoder != address(0x00));

            (address bridge, uint256 value, bytes memory data) =
                IEncoder(encoder).encode(actions[i]);

            (bool success,) = bridge.call{value: value}(data);

            require(success);

            emit SendMultichainAction(chainId, bridge, encoder, hash);
        }
    }
}
