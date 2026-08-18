// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

interface IEncoder {
    /// @notice Thrown when a receiver hub required by the module is not set.
    error InvalidReceiverHub();

    /// @notice Encodes a multi-chain action into bridge calls for SenderHub to make.
    /// @dev This ensures the sender of every message is always SenderHub, rather than the modules.
    /// @param multichainAction The action to dispatch.
    /// @param receiverHub Receiver Hub on the action's target chain, as configured on SenderHub.
    ///        Modules that do not address a receiver may ignore it.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(MultichainAction calldata multichainAction, address receiverHub)
        external
        returns (Call[] memory);
}
