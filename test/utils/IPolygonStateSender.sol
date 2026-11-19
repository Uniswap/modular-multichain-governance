// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Polygon StateSender used by the fork tests.
interface IPolygonStateSender {
    /// @notice Logged for every state sync, this is what Heimdall and Bor derive the call on
    ///         Polygon from.
    /// @param id Id of the state sync, one more than the last.
    /// @param contractAddress State sync receiver on Polygon, the FxChild for an FxRoot message.
    /// @param data For an FxRoot message, `abi.encode` of the caller of the FxRoot, the message's
    ///        receiver on Polygon and the message.
    event StateSynced(uint256 indexed id, address indexed contractAddress, bytes data);

    /// @notice Id of the last state sync.
    function counter() external view returns (uint256);
}
