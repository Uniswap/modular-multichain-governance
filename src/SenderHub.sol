// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract SenderHub is Owned(msg.sender) {
    event EncoderSet(uint256 indexed chainId, bytes32 indexed bridgeId, address indexed module);
    event ActionSent(uint256 indexed chainId, address indexed bridge, address indexed encoder, bytes32 hash);

    mapping(uint256 chainId => mapping(bytes32 bridgeId => address)) encoders;

    function setEncoder(uint256 chainId, bytes32 bridgeId, address encoder) external onlyOwner {
        encoders[chainId][bridgeId] = encoder;

        emit EncoderSet(chainId, bridgeId, encoder);
    }

    function sendMultichainActions(MultichainAction[] calldata actions) external onlyOwner {
        for (uint256 i; i < actions.length; i++) {
            uint256 chainId = actions[i].chainId;
            bytes32 bridgeId = actions[i].bridgeId;
            address encoder = encoders[chainId][bridgeId];

            bytes32 hash = keccak256(abi.encode(actions[i].calls));

            require(encoder != address(0x00));

            (address bridge, uint256 value, bytes memory data) = IEncoder(encoder).encode(actions[i]);

            (bool success,) = bridge.call{value: value}(data);

            require(success);

            emit ActionSent(chainId, bridge, encoder, hash);
        }
    }
}
