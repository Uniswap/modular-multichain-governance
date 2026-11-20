// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Polygon FxChild used by the fork tests.
interface IPolygonFxChild {
    /// @notice Logged for every message, before the receiver is called.
    /// @param rootMessageSender Caller of the FxRoot on Ethereum, not aliased.
    /// @param receiver Message receiver on Polygon.
    /// @param data Message as it was passed to the FxRoot.
    event NewFxMessage(address rootMessageSender, address receiver, bytes data);
}
