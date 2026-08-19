// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {
    Any2EVMMessage,
    IAny2EVMMessageReceiver
} from "src/modules/ccip/IAny2EVMMessageReceiver.sol";
import {Call} from "src/types/Call.sol";

contract CCIPDecoder is IDecoder {
    /// @notice Sender Hub on Ethereum.
    address public immutable SENDER_HUB;

    /// @notice Receiver Hub on local chain.
    address public immutable RECEIVER_HUB;

    /// @notice CCIP Router contract.
    address public immutable ROUTER;

    /// @notice CCIP chain selector for Ethereum L1
    /// @dev This is randomly generated once for every chain.
    /// @dev https://github.com/smartcontractkit/chain-selectors
    uint64 internal constant L1_CHAIN_SELECTOR = 5009297550715157269;

    constructor(address senderHub, address receiverHub, address router) {
        SENDER_HUB = senderHub;
        RECEIVER_HUB = receiverHub;
        ROUTER = router;
    }

    function decode(address caller, bytes calldata data) public view returns (Call[] memory) {
        require(msg.sender == RECEIVER_HUB, CallerNotReceiverHub());
        require(caller == ROUTER);
        require(data.length >= 4, CalldataTooShort());

        bytes4 selector = bytes4(data[:4]);
        require(selector == IAny2EVMMessageReceiver.ccipReceive.selector, InvalidSelector());

        bytes calldata encodedAny2EVMMessage = data[4:];
        Any2EVMMessage memory message = abi.decode(encodedAny2EVMMessage, (Any2EVMMessage));

        require(message.sourceChainSelector == L1_CHAIN_SELECTOR);
        require(abi.decode(message.sender, (address)) == SENDER_HUB);

        return abi.decode(message.data, (Call[]));
    }
}
