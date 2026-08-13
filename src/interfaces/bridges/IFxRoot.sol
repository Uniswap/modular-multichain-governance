// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

interface IFxRoot {
    /// @notice Sends message from FxRoot to FxChild directed at `target`.
    /// @param target Contract on Polygon to call.
    /// @param data Data to send to Polyon target (encoded into `processMessageFromRoot`).
    function sendMessageToChild(address target, bytes memory data) external;
}
