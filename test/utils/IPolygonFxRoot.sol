// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Polygon FxRoot used by the fork tests, beyond what the modules
///         themselves depend on (see `src/interfaces/bridges/IFxRoot.sol`).
interface IPolygonFxRoot {
    /// @notice StateSender the FxRoot hands every message to.
    function stateSender() external view returns (address);

    /// @notice FxChild on Polygon, the state sync receiver of every message.
    function fxChild() external view returns (address);
}
