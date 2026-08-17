// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

/// @title Optimism Portal2 Call Virtual Interface
/// @notice Ensures every OP Stack message reaches the ReceiverHub behind a function selector it
///         can dispatch on.
interface IPortal2Calls {
    /// @notice Custom Optimism Portal2 call function.
    /// @dev OP Stack chains forward the `data` parameter from its Portal2 call directly. We define
    ///      this function to encapsulate the call array such that the ReceiverHub can dispatch the
    ///      Portal2Decoder based on the selector rather than the call array (which has no
    ///      selector).
    function portal2Call(Call[] memory calls) external;
}
