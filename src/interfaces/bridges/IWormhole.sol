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
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VerifiableMessage memory vm, bool valid, string memory reason);

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
            external
            payable
            returns (uint64 sequence);

    function messageFee() external view returns (uint256);
}