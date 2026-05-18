// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {Call} from "src/types/Call.sol";
import {MessageType} from "src/types/MessageType.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {IGuard} from "src/interfaces/IGuard.sol";

contract ReceiverHub is Owned(msg.sender) {
    event DecoderRegistered(address indexed decoder, address indexed module);
    event Veto(bytes32 indexed vetoedHash, address indexed bridge, address indexed decoder);
    event CallsReceived(bytes32 indexed hash, address indexed bridge, address indexed decoder, uint256 value);

    address public guard;
    mapping(address bridge => address) public decoders;

    Call[] public nextCalls;
    bytes32 public nextCallsHash;

    function setGuard(address newGuard) external onlyOwner {
        guard = newGuard;
    }

    function setDecoder(address bridge, address decoder) external onlyOwner {
        decoders[bridge] = decoder;
    }

    function runCalls() external {
        IGuard(guard).authorizeCalls(nextCallsHash);

        uint256 length = nextCalls.length;

        for (uint256 i; i < length; i++) {
            address target = nextCalls[i].target;
            uint256 value = nextCalls[i].value;
            bytes memory data = nextCalls[i].data;

            (bool success, ) = target.call{value: value}(data);

            require(success);
        }
    }

    fallback() external payable {
        address decoder = decoders[msg.sender];
        require(address(decoder) != address(0x00));

        (MessageType messageType, Call[] memory calls) = IDecoder(decoder).decode(msg.sender, msg.data);
        bytes32 hash = keccak256(abi.encode(calls));

        if (messageType == MessageType.Veto) {
            bytes32 vetoedHash = nextCallsHash;

            delete nextCalls;
            delete nextCallsHash;

            emit Veto(vetoedHash, msg.sender, decoder);

        } else if (messageType == MessageType.Multicall) {
            IGuard(guard).commitCalls(msg.sender, calls);

            nextCalls = calls;
            nextCallsHash = hash;

            emit CallsReceived(hash, msg.sender, decoder, msg.value);
        }
    }

    receive() external payable {}
}
