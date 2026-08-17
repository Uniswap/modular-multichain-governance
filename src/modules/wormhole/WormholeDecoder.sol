// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IWormhole, VerifiableMessage} from "src/interfaces/bridges/IWormhole.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeError} from "src/modules/wormhole/WormholeError.sol";
import {Call} from "src/types/Call.sol";
import {CalldataHandler} from "src/util/CalldataHandler.sol";

/// @title Wormhole Decoder
/// @notice Decodes Wormhole "Verifiable Message" messages.
contract WormholeDecoder is IDecoder {
    /// @notice Wormhole-defined chain Id for Ethereum.
    uint16 constant ETH_WORMHOLE_CHAIN_ID = 2;

    /// @notice Message timeout.
    uint256 constant MSG_TIMEOUT = 2 days;

    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    /// @notice Wormhole core on local chain.
    address public immutable WORMHOLE;

    /// @notice Nonce for message sequencing.
    uint256 public nonce;

    constructor(address senderHub, address receiverHub, address wormhole) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        WORMHOLE = wormhole;
    }

    /// @notice Decodes a custom-encoded message containing the encoded Wormhole Verifiable Mesasge.
    /// @dev Anyone can relay a message.
    /// @dev Verification and message format is checked by Wormhole core.
    /// @param data Encoded `wormholeCall` function.
    /// @return Decoded call array.
    function decode(address, bytes calldata data) public returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());

        bytes4 selector = CalldataHandler.getSelector(data);
        require(selector == IWormholeCalls.wormholeCall.selector, InvalidSelector());

        bytes calldata encodedWormholeMessage = CalldataHandler.getCalldataWithoutSelector(data);
        bytes memory wormholeMessage = abi.decode(encodedWormholeMessage, (bytes));

        (VerifiableMessage memory vm, bool valid, string memory reason) =
            IWormhole(WORMHOLE).parseAndVerifyVM(wormholeMessage);

        require(valid, WormholeError.ParseVerifyVM(reason));
        require(SENDER_HUB == address(uint160(uint256(vm.emitterAddress))), NotFromSenderHub());
        require(vm.emitterChainId == ETH_WORMHOLE_CHAIN_ID, WormholeError.NotFromEthereum());
        require(vm.timestamp + MSG_TIMEOUT >= block.timestamp, WormholeError.Expired());
        require(vm.sequence == nonce, WormholeError.InvalidNonce());

        (uint16 receiverChainId, Call[] memory calls) = abi.decode(vm.payload, (uint16, Call[]));
        require(receiverChainId == block.chainid, WormholeError.NotToThisChain());

        nonce += 1;

        return calls;
    }
}
