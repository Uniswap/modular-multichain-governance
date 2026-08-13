// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {MultichainAction} from "src/types/MultichainAction.sol";

interface IEncoder {
    /// @notice Encodes a multi-chain action into parameters for SenderHub to make an external call.
    /// @dev This ensures the sender of the message is always SenderHub, rather than the modules.
    /// @param multichainAction The action to dispatch.
    /// @return Bridge address to call.
    /// @return Value to send to the bridge.
    /// @return Data to send to the bridge.
    function encode(MultichainAction calldata multichainAction)
        external
        returns (address, uint256, bytes memory);
}
