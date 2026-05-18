// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IGuard} from "src/interfaces/IGuard.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";

contract TimelockedRedundant is IGuard, Owned(msg.sender) {
    uint256 public timelock;
    uint256 public reundancyThreshold;
    address public receiverHub;

    bytes32 public currentHash;
    uint256 public readyAt;
    address[] public bridgesCommitted;

    function commitHash(address bridge, bytes32 hash) external {
        require(msg.sender == receiverHub);

        if (currentHash != hash) {
            readyAt = block.timestamp + timelock;
            currentHash = hash;
        }

        uint256 length = bridgesCommitted.length;
        bool alreadyCommitted;

        for (uint256 i; i < length; i++) {
            if (bridgesCommitted[i] == bridge) {
                alreadyCommitted = true;
                break;
            }
        }

        if (!alreadyCommitted) {
            bridgesCommitted.push(bridge);
        }
    }

    function authorizeHash(bytes32 hash) external {
        require(msg.sender == receiverHub);
        require(currentHash == hash);
        require(readyAt >= block.timestamp);
        require(bridgesCommitted.length >= reundancyThreshold);

        delete currentHash;
        delete readyAt;
        delete bridgesCommitted;
    }

    function setTimelock(uint256 newTimelock) external onlyOwner {
        timelock = newTimelock;
    }

    function setRedundancyThreshold(uint256 newRedundancyThreshold) external onlyOwner {
        reundancyThreshold = newRedundancyThreshold;
    }

    function setReceiverHub(address newReceiverHub) external onlyOwner {
        receiverHub = newReceiverHub;
    }
}
