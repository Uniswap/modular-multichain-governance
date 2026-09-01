// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

interface IEncoder {
    /// @notice Thrown when a receiver hub required by the module is not set.
    error InvalidReceiverHub();

    /// @notice Thrown when the call value is invalid.
    /// @dev This handles the case where some bridges disallow non-zero call values in messages.
    error InvalidCallValue();

    /// @notice Thrown when a bridge is not set.
    /// @dev This handles encoders tracks the bridge address in storage and the address is unset.
    error BridgeNotSet();

    /// @notice Thrown when the caller is not the sender hub.
    /// @dev This handles encoders that have stateful `encode` functions gated to the sender hub.
    error NotSenderHub();

    /// @notice Encodes a multi-chain action into bridge calls for SenderHub to make.
    /// @dev This ensures the sender of every message is always SenderHub, rather than the modules.
    /// @param receiverHub Receiver Hub on the action's target chain, as configured on SenderHub.
    ///        Modules that do not address a receiver may ignore it.
    /// @param multichainAction The action to dispatch.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(address receiverHub, MultichainAction calldata multichainAction)
        external
        returns (Call[] memory);
}
