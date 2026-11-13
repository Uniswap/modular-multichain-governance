// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {IWormhole, VerifiableMessage} from "src/interfaces/bridges/IWormhole.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeError} from "src/modules/wormhole/WormholeError.sol";
import {Call} from "src/types/Call.sol";

/// @title Wormhole Decoder
/// @notice Decodes Wormhole "Verifiable Message" messages.
contract WormholeDecoder is IDecoder {
    /// @notice Wormhole-defined chain Id for Ethereum.
    uint16 constant ETH_WORMHOLE_CHAIN_ID = 2;

    /// @notice Message timeout.
    uint256 constant MSG_TIMEOUT = 14 days;

    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    /// @notice Wormhole core on local chain.
    address public immutable WORMHOLE;

    /// @notice Maps message Id's to whether they have been consumed on this chain.
    /// @dev Message Id's are shared across all chains, so the Id's consumed here are not contiguous
    ///      and messages may be relayed in any order.
    mapping(uint256 messageId => bool) public consumed;

    constructor(address senderHub, address receiverHub, address wormhole) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        WORMHOLE = wormhole;
    }

    /// @notice Decodes a custom-encoded message containing the encoded Wormhole Verifiable Mesasge.
    /// @dev Anyone can relay a message.
    /// @dev Verification and message format is checked by Wormhole core.
    /// @dev `vm.emitterChainId` refers to the Wormhole-defined "chainId" system, which is separate
    ///      from the EIP-155 chain Id. The `receiverChainId` refers to the EIP-155 chain Id.
    /// @dev Each message Id is consumed at most once, so a Verifiable Message cannot be replayed.
    /// @param data Encoded `wormholeCall` function.
    /// @return Decoded call array.
    function decode(address, bytes calldata data) public returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());
        require(data.length >= 4, CalldataTooShort());

        bytes4 selector = bytes4(data[:4]);
        require(selector == IWormholeCalls.wormholeCall.selector, InvalidSelector());

        bytes calldata encodedWormholeMessage = data[4:];
        bytes memory wormholeMessage = abi.decode(encodedWormholeMessage, (bytes));

        (VerifiableMessage memory vm, bool valid, string memory reason) =
            IWormhole(WORMHOLE).parseAndVerifyVM(wormholeMessage);

        require(valid, WormholeError.ParseVerifyVM(reason));
        require(SENDER_HUB == address(uint160(uint256(vm.emitterAddress))), NotFromSenderHub());
        require(vm.emitterChainId == ETH_WORMHOLE_CHAIN_ID, WormholeError.NotFromEthereum());
        require(vm.timestamp + MSG_TIMEOUT >= block.timestamp, WormholeError.Expired());

        (uint256 messageId, uint256 receiverChainId, Call[] memory calls) =
            abi.decode(vm.payload, (uint256, uint256, Call[]));
        require(receiverChainId == block.chainid, WormholeError.NotToThisChain());
        require(!consumed[messageId], WormholeError.AlreadyConsumed());

        consumed[messageId] = true;

        return calls;
    }
}
