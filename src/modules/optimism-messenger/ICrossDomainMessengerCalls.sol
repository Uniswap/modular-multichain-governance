// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Call} from "src/types/Call.sol";

/// @title OP Stack CrossDomainMessenger Call Virtual Interface
/// @notice Ensures every CrossDomainMessenger message reaches the ReceiverHub behind a function
///         selector it can dispatch on.
interface ICrossDomainMessengerCalls {
    /// @notice Custom CrossDomainMessenger call function.
    /// @dev The L2CrossDomainMessenger forwards the `message` parameter from the
    ///      L1CrossDomainMessenger call directly. We define this function to encapsulate the call
    ///      array such that the ReceiverHub can dispatch the L1CrossDomainMessengerDecoder based on
    ///      the selector rather than the call array (which has no selector).
    function crossDomainMessengerCall(Call[] memory calls) external;
}
