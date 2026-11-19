// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the Polygon StateReceiver, a genesis contract at `0x1001`, used by the fork
///         tests.
interface IPolygonStateReceiver {
    /// @notice Logged for every state sync whose receiver is a contract.
    /// @param stateId Id of the state sync.
    /// @param success False if the receiver reverted or ran out of the gas it was given.
    event StateCommitted(uint256 indexed stateId, bool success);

    /// @notice Logged when a failed state sync is replayed, before the receiver is called.
    event StateSyncReplay(uint256 indexed stateId);

    /// @notice Calls the receiver of a state sync with `receiverGas`, without reverting if the
    ///         call fails. Only Bor can call this, as the system address.
    /// @param syncTime Time Heimdall recorded the state sync at, unused.
    /// @param recordBytes RLP list of the state sync's id, receiver and data, followed by fields
    ///        that are not read.
    function commitState(uint256 syncTime, bytes calldata recordBytes)
        external
        returns (bool success);

    /// @notice Calls the receiver of a failed state sync again, with all of the caller's gas.
    ///         Anyone can call this. Reverts if the receiver does, the state sync then stays
    ///         replayable.
    /// @param stateId Id of the failed state sync.
    /// @param receiver Receiver the state sync was committed with.
    /// @param stateData Data the state sync was committed with.
    function replayFailedStateSyncWithData(
        uint256 stateId,
        address receiver,
        bytes calldata stateData
    ) external;

    /// @notice Gas `commitState` forwards to a state sync's receiver, read from a gas oracle and
    ///         capped at five million.
    function receiverGas(uint256 stateId, address receiver, bytes calldata stateData)
        external
        view
        returns (uint256);

    /// @notice Id of the last state sync committed.
    function lastStateId() external view returns (uint256);

    /// @notice Hash of `abi.encode(receiver, stateData)` for a failed state sync, zero if the
    ///         state sync succeeded or has been replayed.
    function failedStateSyncHashes(uint256 stateId) external view returns (bytes32);
}
