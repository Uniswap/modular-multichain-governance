// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IWormhole, Signature, VerifiableMessage} from "src/interfaces/bridges/IWormhole.sol";

contract MockWormhole is IWormhole {
    uint256 internal _messageFee;

    VerifiableMessage internal _message;
    bool internal _valid;
    string internal _reason;

    uint256 public publishCount;
    uint32 public lastNonce;
    bytes public lastPayload;
    uint8 public lastConsistencyLevel;
    uint256 public lastValue;
    uint64 public nextSequence;

    function setMessageFee(uint256 newMessageFee) external {
        _messageFee = newMessageFee;
    }

    function setNextSequence(uint64 sequence) external {
        nextSequence = sequence;
    }

    function setParseAndVerifyVM(VerifiableMessage memory message, bool valid, string memory reason)
        external
    {
        _message.version = message.version;
        _message.timestamp = message.timestamp;
        _message.nonce = message.nonce;
        _message.emitterChainId = message.emitterChainId;
        _message.emitterAddress = message.emitterAddress;
        _message.sequence = message.sequence;
        _message.consistencyLevel = message.consistencyLevel;
        _message.payload = message.payload;
        _message.guardianSetIndex = message.guardianSetIndex;
        _message.hash = message.hash;

        delete _message.signatures;
        for (uint256 i; i < message.signatures.length; i++) {
            _message.signatures
                .push(
                    Signature({
                        r: message.signatures[i].r,
                        s: message.signatures[i].s,
                        v: message.signatures[i].v,
                        guardianIndex: message.signatures[i].guardianIndex
                    })
                );
        }

        _valid = valid;
        _reason = reason;
    }

    function messageFee() external view returns (uint256) {
        return _messageFee;
    }

    function parseAndVerifyVM(bytes calldata)
        external
        view
        returns (VerifiableMessage memory, bool, string memory)
    {
        return (_message, _valid, _reason);
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64)
    {
        publishCount += 1;
        lastNonce = nonce;
        lastPayload = payload;
        lastConsistencyLevel = consistencyLevel;
        lastValue = msg.value;

        return nextSequence;
    }
}
