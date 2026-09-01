// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";

/// @title Receiver Hub.
/// @notice Receives messages from arbitrary bridges, dispatches decoders, and forwards the decoded
///         calls as the owner of the Uniswap protocol on the respective chain.
contract ReceiverHub is Owned(msg.sender), IReceiverHub {
    /// @inheritdoc IReceiverHub
    mapping(bytes4 selector => address) public decoders;

    /// @inheritdoc IReceiverHub
    mapping(bytes4 interfaceId => bool) public supportsInterface;

    /// @inheritdoc IReceiverHub
    function setDecoder(bytes4 selector, address decoder) public onlyOwner {
        decoders[selector] = decoder;

        emit SetDecoder(selector, decoder);
    }

    /// @inheritdoc IReceiverHub
    function setSupportsInterface(bytes4 interfaceId, bool support) public onlyOwner {
        supportsInterface[interfaceId] = support;

        emit SetSupportsInterface(interfaceId, support);
    }

    /// @inheritdoc IReceiverHub
    fallback() external payable {
        address decoder = decoders[msg.sig];
        require(address(decoder) != address(0x00), NoDecoderForSelector(msg.sig));

        Call[] memory calls = IDecoder(decoder).decode(msg.sender, msg.data);

        for (uint256 i; i < calls.length; i++) {
            address target = calls[i].target;
            uint256 value = calls[i].value;
            bytes memory data = calls[i].data;

            (bool success, bytes memory returnedData) = target.call{value: value}(data);

            require(success, CallFail(target, returnedData));
        }

        emit CallsReceived(msg.sender, msg.sig, decoder);
    }

    /// @inheritdoc IReceiverHub
    receive() external payable {}
}
