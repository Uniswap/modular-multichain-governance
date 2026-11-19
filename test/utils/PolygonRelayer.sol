// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {IPolygonStateReceiver} from "test/utils/IPolygonStateReceiver.sol";
import {IPolygonStateSender} from "test/utils/IPolygonStateSender.sol";

/// @title Polygon Relayer
/// @notice Stands in for Heimdall and Bor in fork tests. Reads the state syncs a StateSender
///         logged on the L1 fork and commits them to the StateReceiver on whichever fork is active.
/// @dev The StateReceiver is a genesis contract with real code on a fork, so unlike the other
///      relayers this one runs the bridge's own code on the remote side. What it models is the
///      part that happens off chain:
///
///      - Heimdall drops the data of a state sync larger than `MAX_STATE_SYNC_SIZE`, the state
///        sync is still committed, with empty data
///      - Bor calls `commitState` as the system address, with the state sync as an RLP record
///      - Bor commits state syncs in order, here the ones pending between the two fork blocks are
///        skipped by moving the StateReceiver's last id up to the one before the relayed sync
///
///      Everything after that is the StateReceiver's doing: the gas the receiver gets, the failed
///      state sync it records and the replay.
///
///      Where it departs from Bor: the record's transaction hash and log index are zero, and a
///      state sync is committed right away rather than after Heimdall's confirmation delay.
library PolygonRelayer {
    /// @dev State sync derived from a `StateSynced` log.
    struct StateSync {
        uint256 id;
        address receiver;
        bytes data;
    }

    /// @notice Thrown when the active fork has already committed a state sync with this id, which
    ///         is the case if it is relayed twice or the fork blocks are out of order.
    error StateSyncAlreadyCommitted(uint256 id, uint256 lastStateId);

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Polygon's StateReceiver.
    address internal constant STATE_RECEIVER = 0x0000000000000000000000000000000000001001;

    /// @dev Largest state sync data Heimdall passes on, in bytes.
    uint256 internal constant MAX_STATE_SYNC_SIZE = 30_000;

    /// @dev Address Bor makes system calls from.
    address private constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @dev Storage slot of the StateReceiver's `lastStateId`.
    bytes32 private constant LAST_STATE_ID_SLOT = 0;

    /// @notice Extracts the state syncs `stateSender` logged, in order.
    /// @param logs Logs recorded on the L1 fork with `vm.recordLogs`.
    /// @param stateSender StateSender to read state syncs from, logs from other emitters are
    ///        skipped.
    function stateSyncs(Vm.Log[] memory logs, address stateSender)
        internal
        pure
        returns (StateSync[] memory found)
    {
        found = new StateSync[](logs.length);
        uint256 count;

        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.emitter != stateSender) continue;
            if (log.topics[0] != IPolygonStateSender.StateSynced.selector) continue;

            found[count++] = StateSync({
                id: uint256(log.topics[1]),
                receiver: address(uint160(uint256(log.topics[2]))),
                data: abi.decode(log.data, (bytes))
            });
        }

        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    /// @notice Commits a state sync on the active fork, which calls its receiver.
    /// @return success False if the receiver reverted or ran out of the gas the StateReceiver gave
    ///         it, the state sync can then be replayed.
    function relay(StateSync memory sync) internal returns (bool success) {
        uint256 lastStateId = uint256(VM.load(STATE_RECEIVER, LAST_STATE_ID_SLOT));
        require(lastStateId < sync.id, StateSyncAlreadyCommitted(sync.id, lastStateId));

        VM.store(STATE_RECEIVER, LAST_STATE_ID_SLOT, bytes32(sync.id - 1));

        VM.prank(SYSTEM, SYSTEM);
        success = IPolygonStateReceiver(STATE_RECEIVER).commitState(block.timestamp, record(sync));
    }

    /// @notice Replays a failed state sync on the active fork, as anyone can on Polygon by calling
    ///         `replayFailedStateSyncWithData`.
    /// @return success False if the receiver reverted, the state sync can then be replayed again.
    /// @return returnData Data the receiver reverted with, empty if it did not.
    function replay(StateSync memory sync)
        internal
        returns (bool success, bytes memory returnData)
    {
        (success, returnData) = STATE_RECEIVER.call(
            abi.encodeCall(
                IPolygonStateReceiver.replayFailedStateSyncWithData,
                (sync.id, sync.receiver, committedData(sync))
            )
        );
    }

    /// @notice Data a state sync is committed with on Polygon, the data logged on L1 unless
    ///         Heimdall dropped it for its size.
    function committedData(StateSync memory sync) internal pure returns (bytes memory) {
        return sync.data.length > MAX_STATE_SYNC_SIZE ? bytes("") : sync.data;
    }

    /// @dev Encodes a state sync as the record Bor passes to `commitState`, an RLP list of:
    ///
    ///      | id | receiver | data | transaction hash | log index | chain id |
    ///
    ///      The StateReceiver reads the first three.
    function record(StateSync memory sync) private view returns (bytes memory) {
        bytes memory items = abi.encodePacked(
            rlpUint(sync.id),
            rlpBytes(abi.encodePacked(sync.receiver)),
            rlpBytes(committedData(sync)),
            rlpBytes(abi.encodePacked(bytes32(0x00))),
            rlpUint(0),
            rlpBytes(bytes(VM.toString(block.chainid)))
        );

        return abi.encodePacked(rlpPrefix(items.length, 0xc0), items);
    }

    /// @dev RLP encoding of an integer, its big endian bytes without leading zeros as a string.
    function rlpUint(uint256 value) private pure returns (bytes memory) {
        return rlpBytes(bigEndian(value));
    }

    /// @dev RLP encoding of a string.
    function rlpBytes(bytes memory value) private pure returns (bytes memory) {
        if (value.length == 1 && uint8(value[0]) < 0x80) return value;

        return abi.encodePacked(rlpPrefix(value.length, 0x80), value);
    }

    /// @dev RLP prefix of a payload of `length` bytes, `offset` is 0x80 for a string and 0xc0 for
    ///      a list.
    function rlpPrefix(uint256 length, uint256 offset) private pure returns (bytes memory) {
        if (length < 56) return bigEndian(offset + length);

        bytes memory lengthBytes = bigEndian(length);

        return abi.encodePacked(bigEndian(offset + 55 + lengthBytes.length), lengthBytes);
    }

    /// @dev Big endian bytes of `value` without leading zeros, empty for zero.
    function bigEndian(uint256 value) private pure returns (bytes memory trimmed) {
        uint256 length;
        for (uint256 rest = value; rest != 0; rest >>= 8) {
            length++;
        }

        trimmed = new bytes(length);

        assembly ("memory-safe") {
            mstore(add(trimmed, 0x20), shl(mul(sub(32, length), 8), value))
        }
    }
}
