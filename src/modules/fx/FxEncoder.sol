// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Polygon Fx Encoder.
/// @notice Encodes message to send to FxRoot on Ethereum (Polygon's bridge).
contract FxEncoder is IEncoder {
    /// @notice Polygon's FxRoot.
    address public immutable FX_ROOT;

    constructor(address fxRoot) {
        FX_ROOT = fxRoot;
    }

    /// @notice Encodes a multichain action for the Polygon FxRoot.
    /// @dev Call value MUST be zero.
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

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: FX_ROOT,
            value: 0,
            data: abi.encodeCall(
                IFxRoot.sendMessageToChild, (receiverHub, abi.encode(multichainAction.calls))
            )
        });

        return bridgeCalls;
    }
}
