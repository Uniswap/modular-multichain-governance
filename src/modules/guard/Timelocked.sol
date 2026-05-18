// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IGuard} from "src/interfaces/IGuard.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {Call} from "src/types/Call.sol";

contract Timelocked is IGuard, Owned(msg.sender) {
    event TimelockSet(uint256 indexed newTimelock);
    event ReceiverHubSet(address indexed newReceiverHub);

    address public receiverHub;
    uint256 public timelock;

    bytes32 public currentHash;
    uint256 public readyAt;

    function commitCalls(address, Call[] calldata calls) external onlyOwner {
        bytes32 hash = keccak256(abi.encode(calls));

        if (currentHash == hash) {
            return;
        }

        readyAt = block.timestamp + timelock;

        currentHash = hash;
    }

    function authorizeCalls(bytes32 callsHash) external onlyOwner {
        require(currentHash == callsHash);
        require(readyAt >= block.timestamp);

        delete currentHash;
        delete readyAt;
    }

    function setTimelock(uint256 newTimelock) external onlyOwner {
        timelock = newTimelock;

        emit TimelockSet(newTimelock);
    }

    function setReceiverHub(address newReceiverHub) external onlyOwner {
        receiverHub = newReceiverHub;

        emit ReceiverHubSet(newReceiverHub);
    }
}
