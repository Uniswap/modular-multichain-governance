// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

struct VerifiableMessage {
    uint8 version;
    uint32 timestamp;
    uint32 nonce;
    uint16 emitterChainId;
    bytes32 emitterAddress;
    uint64 sequence;
    uint8 consistencyLevel;
    bytes payload;
    uint32 guardianSetIndex;
    Signature[] signatures;
    bytes32 hash;
}

struct Signature {
    bytes32 r;
    bytes32 s;
    uint8 v;
    uint8 guardianIndex;
}

interface IWormhole {
    /// @dev Checks message is valid & returns decoded data.
    /// @param encodedVM Encoded message as displayed in Wormhole explorer.
    /// @return vm Verfiable Message data structure.
    /// @return valid True if the message has been validated by Wormhole nodes.
    /// @return reason Non-empty if `valid` is false, explains why the message is not valid.
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VerifiableMessage memory vm, bool valid, string memory reason);

    /// @dev Publishes a message to the Wormhole.
    /// @param nonce Message nonce to forward to the receiver.
    /// @param payload Encoded data to forward to the receiver.
    /// @param consistencyLevel If it's `1`, it means "finalized on Ethereum".
    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
            external
            payable
            returns (uint64 sequence);

    /// @dev Message Fee for Wormhole team.
    function messageFee() external view returns (uint256);
}
