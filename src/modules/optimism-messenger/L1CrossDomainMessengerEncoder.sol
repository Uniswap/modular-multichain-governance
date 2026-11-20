// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title OP Stack L1CrossDomainMessenger Encoder
/// @notice Encodes messages for the L1CrossDomainMessenger of OP Stack chains.
/// @dev The messenger deposits through the chain's OptimismPortal2. Unlike a deposit made on the
///      portal directly, a message whose call fails on the remote chain is recorded by the
///      L2CrossDomainMessenger, which holds the Ether the message carries until anyone relays it
///      again.
contract L1CrossDomainMessengerEncoder is Owned(msg.sender), IEncoder {
    /// @notice Logged when the minimum gas limit is set.
    /// @param minGasLimit New minimum gas limit.
    event SetMinGasLimit(uint32 minGasLimit);

    /// @notice Logged when an OP Stack chain's L1CrossDomainMessenger is set.
    /// @param chainId OP Stack chain's chain Id.
    /// @param messenger Chain's L1CrossDomainMessenger.
    event SetMessenger(uint256 indexed chainId, address indexed messenger);

    /// @notice Least gas the Receiver Hub is called with on the remote chain.
    /// @dev The messenger buys this much gas and its own overhead on top. A message that needs
    ///      more fails on the remote chain and can be relayed again with more gas.
    uint32 public minGasLimit;

    /// @notice Maps chain Id's to L1CrossDomainMessengers.
    mapping(uint256 chainId => address) public messengers;

    /// @notice Sets the minimum gas limit.
    /// @param newMinGasLimit New minimum gas limit.
    function setMinGasLimit(uint32 newMinGasLimit) external onlyOwner {
        minGasLimit = newMinGasLimit;

        emit SetMinGasLimit(newMinGasLimit);
    }

    /// @notice Sets the L1CrossDomainMessenger for a given chain Id.
    /// @param chainId OP Stack chain's chain Id.
    /// @param messenger OP Stack chain's L1CrossDomainMessenger.
    function setMessenger(uint256 chainId, address messenger) external onlyOwner {
        messengers[chainId] = messenger;

        emit SetMessenger(chainId, messenger);
    }

    /// @notice Encodes a multichain action for an OP Stack L1CrossDomainMessenger.
    /// @dev The L1CrossDomainMessenger is unique to each OP Stack chain.
    /// @dev The value is the sum of all call values, the messenger forwards all of it.
    /// @dev The data is an array of calls behind a `crossDomainMessengerCall` function selector.
    /// @param receiverHub Receiver Hub on the remote chain. MUST be set on SenderHub.
    /// @param multichainAction Action to send to the OP Stack chain.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(address receiverHub, MultichainAction calldata multichainAction)
        public
        view
        returns (Call[] memory)
    {
        require(receiverHub != address(0x00), InvalidReceiverHub());

        address messenger = messengers[multichainAction.chainId];

        require(messenger != address(0x00), BridgeNotSet());

        uint256 value = 0;

        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: messenger,
            value: value,
            data: abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall,
                        (multichainAction.calls)
                    ),
                    minGasLimit
                )
            )
        });

        return bridgeCalls;
    }
}
