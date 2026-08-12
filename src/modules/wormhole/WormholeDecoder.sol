// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {DecoderError, WormholeError} from "src/util/Errors.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";
import {VerifiableMessage, IWormhole} from "src/interfaces/bridges/IWormhole.sol";

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
        require(msg.sender == RECEIVER_HUB, DecoderError.CallerNotReceiverHub());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IBridgeCalls.wormholeCall.selector, DecoderError.InvalidSelector());

        bytes memory encodedWormholeMessage = CalldataHandler.getCalldataWithoutSelector(data);
        bytes memory wormholeMessage = abi.decode(encodedWormholeMessage, (bytes));

        (VerifiableMessage memory vm, bool valid, string memory reason) =
            IWormhole(WORMHOLE).parseAndVerifyVM(wormholeMessage);

        require(valid, WormholeError.ParseVerifyVM(reason));
        require(
            SENDER_HUB == address(uint160(uint256(vm.emitterAddress))), DecoderError.NotFromSenderHub()
        );
        require(vm.emitterChainId == ETH_WORMHOLE_CHAIN_ID, WormholeError.NotFromEthereum());
        require(vm.timestamp + MSG_TIMEOUT >= block.timestamp, WormholeError.Expired());
        require(vm.sequence >= minimumNonce, WormholeError.InvalidNonce());

        (uint16 receiverChainId, Call[] memory calls) = abi.decode(vm.payload, (uint16, Call[]));
        require(receiverChainId == THIS_WORMHOLE_CHAIN_ID, WormholeError.NotToThisChain());

        minimumNonce = vm.sequence + 1;

        return calls;
    }
}
