// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {Call} from "src/types/Call.sol";

contract ReceiverHub is Owned(msg.sender) {
    event DecoderRegistered(bytes4 indexed selector, address indexed decoder);
    event CallsReceived(address indexed bridge, address indexed decoder, bytes32 indexed callsHash);

    mapping(bytes4 selector => address) public decoders;

    function setDecoder(bytes4 selector, address decoder) external onlyOwner {
        decoders[selector] = decoder;

        emit DecoderRegistered(selector, decoder);
    }

    fallback() external payable {
        address decoder = decoders[msg.sig];
        require(address(decoder) != address(0x00));

        Call[] memory calls = IDecoder(decoder).decode(msg.sender, msg.data);

        bytes32 callsHash = keccak256(abi.encode(calls));

        for (uint256 i; i < calls.length; i++) {
            address target = calls[i].target;
            uint256 value = calls[i].value;
            bytes memory data = calls[i].data;

            (bool success,) = target.call{value: value}(data);

            require(success);
        }

        emit CallsReceived(msg.sender, decoder, callsHash);
    }

    receive() external payable {}
}
