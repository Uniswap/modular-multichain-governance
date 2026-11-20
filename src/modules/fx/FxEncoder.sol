// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {FxError} from "src/modules/fx/FxError.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Polygon Fx Encoder.
/// @notice Encodes message to send to FxRoot on Ethereum (Polygon's bridge).
contract FxEncoder is IEncoder {
    /// @notice Polygon's FxRoot.
    address public immutable FX_ROOT;

    /// @notice Largest state sync, in bytes, that Polygon's validators relay with its data.
    /// @dev A larger state sync is accepted by the FxRoot but reaches Polygon with empty data,
    ///      which the FxChild cannot decode, and the action is lost.
    uint256 public constant MAX_STATE_SYNC_SIZE = 30_000;

    /// @dev Bytes the FxRoot adds to a message whose length is a whole number of words. It syncs
    ///      `abi.encode(msg.sender, receiver, message)`, three head words and the message's length.
    uint256 internal constant STATE_SYNC_OVERHEAD = 128;

    constructor(address fxRoot) {
        FX_ROOT = fxRoot;
    }

    /// @notice Encodes a multichain action for the Polygon FxRoot.
    /// @dev Call value MUST be zero. The state sync the FxRoot sends for the action MUST NOT be
    ///      larger than `MAX_STATE_SYNC_SIZE`.
    /// @param receiverHub Receiver Hub on the remote chain. MUST be set on SenderHub.
    /// @param multichainAction Action to send to Polygon.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(address receiverHub, MultichainAction calldata multichainAction)
        public
        view
        returns (Call[] memory)
    {
        require(receiverHub != address(0x00), InvalidReceiverHub());

        for (uint256 i; i < multichainAction.calls.length; ++i) {
            require(multichainAction.calls[i].value == 0, InvalidCallValue());
        }

        bytes memory message = abi.encode(multichainAction.calls);
        require(
            STATE_SYNC_OVERHEAD + message.length <= MAX_STATE_SYNC_SIZE, FxError.StateSyncTooLarge()
        );

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: FX_ROOT,
            value: 0,
            data: abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, message))
        });

        return bridgeCalls;
    }
}
