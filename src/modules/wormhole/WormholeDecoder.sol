// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Errors} from "./Errors.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

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
}

contract WormholeDecoder is IDecoder {
    uint16 constant ETH_WORMHOLE_CHAIN_ID = 2;
    uint256 constant MSG_TIMEOUT = 2 days;

    address public immutable SENDER_HUB;
    address public immutable RECEIVER_HUB;
    address public immutable WORMHOLE;
    uint16 public immutable THIS_WORMHOLE_CHAIN_ID;

    uint256 public minimumNonce;

    constructor(address senderHub, address receiverHub, address wormhole, uint16 thisChainId) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        WORMHOLE = wormhole;
        THIS_WORMHOLE_CHAIN_ID = thisChainId;
    }

    function decode(address, bytes calldata data) public returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, Errors.CallerNotReceiverHub());
        require(getSelector(data) == IBridgeCalls.wormholeCall.selector, Errors.InvalidSelector());

        (VerifiableMessage memory vm, bool valid, string memory reason) =
            IWormhole(WORMHOLE).parseAndVerifyVM(getWormholeMessage(data));

        require(valid, Errors.WormholeParseVerifyVM(reason));
        require(
            SENDER_HUB == address(uint160(uint256(vm.emitterAddress))), Errors.NotFromSenderHub()
        );
        require(vm.emitterChainId == ETH_WORMHOLE_CHAIN_ID, Errors.NotFromEthereum());
        require(vm.timestamp + MSG_TIMEOUT >= block.timestamp, Errors.Expired());
        require(vm.sequence >= minimumNonce, Errors.InvalidNonce());

        (uint16 receiverChainId, Call[] memory calls) = abi.decode(vm.payload, (uint16, Call[]));

        require(receiverChainId == THIS_WORMHOLE_CHAIN_ID, Errors.NotToThisChain());

        minimumNonce = vm.sequence + 1;

        return calls;
    }

    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := calldataload(encodedCall.offset)
            selector := shl(0xe0, shr(0xe0, selector))
        }
    }

    function getWormholeMessage(bytes calldata encodedCall) internal pure returns (bytes memory) {
        bytes memory wormholeMessage = new bytes(0);

        assembly ("memory-safe") {
            let src := add(encodedCall.offset, 0x24)
            let length := calldataload(src)
            wormholeMessage := mload(0x40)
            calldatacopy(src, wormholeMessage, length)
            mstore(0x40, add(wormholeMessage, length))
        }

        return wormholeMessage;
    }
}
