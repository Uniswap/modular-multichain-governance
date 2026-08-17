// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

/// @title Arbitrum Orbit Call Virtual Interface
/// @notice Ensures every Arbitrum Orbit message reaches the ReceiverHub behind a function
///         selector it can dispatch on.
interface IArbitrumCalls {
    /// @notice Custom Arbitrum Orbit call function.
    /// @dev Arbitrum Orbit chains forward the `data` parameter from its Inbox call directly. We
    ///      define this function to encapsulate the call array such that the ReceiverHub can
    ///      dispatch the InboxDecoder based on the selector rather than the call array (which has
    ///      no selector).
    function arbitrumCall(Call[] memory calls) external;
}
