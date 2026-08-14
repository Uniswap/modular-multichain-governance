// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Polygon Fx Encoder.
/// @notice Encodes message to send to FxRoot on Ethereum (Polygon's bridge).
contract FxEncoder is IEncoder {
    /// @notice Polygon's FxRoot.
    address public immutable FX_ROOT;

    /// @notice Sender Hub.
    address public immutable SENDER_HUB;

    constructor(address fxRoot, address senderHub) {
        FX_ROOT = fxRoot;
        SENDER_HUB = senderHub;
    }

    /// @notice Encodes a multichain action for the Polygon FxRoot.
    /// @dev Call value MUST be zero.
    /// @param multichainAction Action to send to Polygon.
    /// @return FxRoot contract.
    /// @return Value to send to FxRoot.
    /// @return Data to send to FxRoot.
    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address receiverHub = ISenderHub(SENDER_HUB).receiverHubs(multichainAction.chainId);

        return (
            FX_ROOT,
            0,
            abi.encodeCall(
                IFxRoot.sendMessageToChild, (receiverHub, abi.encode(multichainAction.calls))
            )
        );
    }
}
