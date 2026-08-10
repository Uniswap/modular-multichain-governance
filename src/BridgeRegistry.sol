// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";

contract BridgeRegistry is Owned(msg.sender) {
    address public senderHub;
    mapping(bytes32 => address) public receiverHubs;

    mapping(bytes32 => string) public bridgeName;
    mapping(string => bytes32) public bridgeId;

    function setSenderHub(address newSenderHub) external onlyOwner {
        senderHub = newSenderHub;
    }

    function setReceiverHub(bytes32 id, address receiverHub) external onlyOwner {
        receiverHubs[id] = receiverHub;
    }

    /// @notice Registers bridge Id's and names for easy two-way lookup.
    /// @dev This has no bearing on the protocol's functionality, it serves to explain otherwise
    ///      unknown bridge Id's.
    /// @param names Bridge names to set.
    function setBridgeIds(string[] calldata names) external onlyOwner {
        for (uint256 i; i < names.length; i++) {
            string calldata name = names[i];
            bytes32 id = keccak256(bytes(name));

            bridgeName[id] = name;
            bridgeId[name] = id;
        }
    }

    /// @notice Removes bridge Id's and names for easy two-way lookup.
    /// @param names Bridge names to unset.
    function unsetBridgeIds(string[] calldata names) external onlyOwner {
        for (uint256 i; i < names.length; i++) {
            string calldata name = names[i];
            bytes32 id = keccak256(bytes(name));

            delete bridgeName[id];
            delete bridgeId[name];
        }
    }
}
