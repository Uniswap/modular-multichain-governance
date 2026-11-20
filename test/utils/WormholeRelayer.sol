// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {IWormholeCore} from "test/utils/IWormholeCore.sol";

/// @title Wormhole Relayer
/// @notice Stands in for the Wormhole guardians in fork tests, and for whoever submits what they
///         signed. Reads the messages a Wormhole core logged on the fork they were published on,
///         signs them into Verifiable Messages and hands those to a ReceiverHub on whichever fork
///         is active.
/// @dev The core is a deployed contract with real code on every fork, so publishing a message
///      and parsing and verifying a Verifiable Message are the bridge's own doing. What is
///      modelled is the part that happens off chain, the guardians observing a message and
///      signing it:
///
///      - a message is identified by its body, which takes the publishing block's timestamp, the
///        publishing core's Wormhole chain id and the emitter, sequence, nonce, consistency level
///        and payload the core logged
///      - each guardian signs the hash of the body, a Verifiable Message carries the signatures
///        of a quorum of one guardian set, ordered by guardian index
///      - the same Verifiable Message verifies on every chain whose core has that guardian set,
///        it is not addressed to a chain or to a receiver
///
///      The guardians' keys are not ours to sign with, so `replaceGuardians` overwrites the keys
///      of a core's current guardian set with keys derived here. The set keeps its index and its
///      size, so the quorum the core asks for is the one it asks for on the real chain. A guardian
///      set upgrade, on the other hand, goes through the core's own governance, see
///      `rotateGuardians`.
///
///      Where it departs from the guardians: a message is signed right away rather than once its
///      block has reached the message's consistency level, and by exactly the guardians asked for
///      rather than by whoever of the nineteen observed it first.
///
///      Not to be confused with Wormhole's own relayer contracts, which deliver a message to a
///      receiver for a fee. The modules do not use them, anyone may submit a Verifiable Message
///      to the ReceiverHub.
library WormholeRelayer {
    /// @dev Message derived from a `LogMessagePublished` log, the body of a Verifiable Message.
    struct Message {
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
    }

    /// @notice Thrown when the core does not report the guardians written to its storage, which
    ///         is the case if its storage layout is not the one assumed here.
    error GuardiansNotReplaced(address wormhole);

    /// @notice Thrown when the core does not report the message fee written to its storage.
    error MessageFeeNotSet(address wormhole);

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Time a replaced guardian set's signatures are still accepted for.
    uint256 internal constant GUARDIAN_SET_EXPIRY = 1 days;

    /// @dev Version of a Verifiable Message, the only one the core parses.
    uint8 private constant VERSION = 1;

    /// @dev Byte length of one packed signature, see `signatures`.
    uint256 private constant SIGNATURE_LENGTH = 66;

    /// @dev Storage slot of the core's `guardianSets` mapping.
    uint256 private constant GUARDIAN_SETS_SLOT = 2;

    /// @dev Storage slot of the core's `messageFee`.
    uint256 private constant MESSAGE_FEE_SLOT = 7;

    /// @dev Module a governance message for the core names, "Core" left-padded to a word.
    bytes32 private constant CORE_MODULE = bytes32(uint256(0x436f7265));

    /// @dev Governance action of a guardian set upgrade.
    uint8 private constant GUARDIAN_SET_UPGRADE = 2;

    /// @notice Extracts the messages `wormhole` logged, in order.
    /// @dev Call it on the fork the logs were recorded on, before its block changes, the messages
    ///      take that block's timestamp and that core's Wormhole chain id.
    /// @param logs Logs recorded with `vm.recordLogs`.
    /// @param wormhole Core to read messages from, logs from other emitters are skipped.
    function messages(Vm.Log[] memory logs, address wormhole)
        internal
        view
        returns (Message[] memory found)
    {
        found = new Message[](logs.length);
        uint256 count;

        uint32 timestamp = uint32(VM.getBlockTimestamp());
        uint16 emitterChainId = IWormholeCore(wormhole).chainId();

        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.emitter != wormhole) continue;
            if (log.topics[0] != IWormholeCore.LogMessagePublished.selector) continue;

            (uint64 sequence, uint32 nonce, bytes memory payload, uint8 consistencyLevel) =
                abi.decode(log.data, (uint64, uint32, bytes, uint8));

            found[count++] = Message({
                timestamp: timestamp,
                nonce: nonce,
                emitterChainId: emitterChainId,
                emitterAddress: log.topics[1],
                sequence: sequence,
                consistencyLevel: consistencyLevel,
                payload: payload
            });
        }

        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    /// @notice Signs a message as a quorum of the current guardian set of `wormhole` on the active
    ///         fork, its first guardians.
    /// @dev The guardian set has to be one the relayer has the keys of, see `replaceGuardians`.
    /// @return Encoded Verifiable Message, as `IWormholeCalls.wormholeCall` takes it.
    function sign(Message memory message, address wormhole) internal view returns (bytes memory) {
        uint32 guardianSetIndex = IWormholeCore(wormhole).getCurrentGuardianSetIndex();
        uint256 guardians = IWormholeCore(wormhole).getGuardianSet(guardianSetIndex).keys.length;

        return sign(message, guardianSetIndex, 0, quorum(guardians));
    }

    /// @notice Signs a message as `count` guardians of the relayer's guardian set `guardianSetIndex`,
    ///         from guardian `first` on.
    /// @return Encoded Verifiable Message, as `IWormholeCalls.wormholeCall` takes it.
    function sign(Message memory message, uint32 guardianSetIndex, uint256 first, uint256 count)
        internal
        pure
        returns (bytes memory)
    {
        return
            encode(message, guardianSetIndex, signatures(message, guardianSetIndex, first, count));
    }

    /// @notice Submits a Verifiable Message to a Receiver Hub on the active fork, as anyone can.
    /// @return success False if the Receiver Hub reverted, which leaves the message unconsumed.
    /// @return returnData Data the Receiver Hub reverted with, empty if it did not.
    function relay(address receiverHub, bytes memory encodedVM)
        internal
        returns (bool success, bytes memory returnData)
    {
        (success, returnData) =
            receiverHub.call(abi.encodeCall(IWormholeCalls.wormholeCall, (encodedVM)));
    }

    /// @notice Replaces the guardians of the current guardian set of `wormhole` on the active
    ///         fork with the relayer's, as many as there were.
    function replaceGuardians(address wormhole) internal {
        uint32 guardianSetIndex = IWormholeCore(wormhole).getCurrentGuardianSetIndex();
        uint256 guardians = IWormholeCore(wormhole).getGuardianSet(guardianSetIndex).keys.length;

        // A guardian set's slot holds the length of its `keys`, which stays as it is, and the
        // hash of that slot is where the keys start.
        bytes32 guardianSetSlot =
            keccak256(abi.encode(uint256(guardianSetIndex), GUARDIAN_SETS_SLOT));
        uint256 keysSlot = uint256(keccak256(abi.encode(guardianSetSlot)));

        for (uint256 i; i < guardians; i++) {
            VM.store(
                wormhole,
                bytes32(keysSlot + i),
                bytes32(uint256(uint160(guardian(guardianSetIndex, i))))
            );
        }

        address[] memory keys = IWormholeCore(wormhole).getGuardianSet(guardianSetIndex).keys;

        require(keys.length == guardians, GuardiansNotReplaced(wormhole));

        for (uint256 i; i < guardians; i++) {
            require(keys[i] == guardian(guardianSetIndex, i), GuardiansNotReplaced(wormhole));
        }
    }

    /// @notice Upgrades `wormhole` on the active fork to the relayer's next guardian set, of the
    ///         size of the current one, with a governance message the current set signs.
    /// @dev The current guardian set has to be one the relayer has the keys of. This is the
    ///      core's own upgrade, so what happens to the replaced set is its doing.
    function rotateGuardians(address wormhole) internal {
        IWormholeCore core = IWormholeCore(wormhole);

        uint32 guardianSetIndex = core.getCurrentGuardianSetIndex();
        uint256 guardians = core.getGuardianSet(guardianSetIndex).keys.length;

        bytes memory keys;

        for (uint256 i; i < guardians; i++) {
            keys = abi.encodePacked(keys, guardian(guardianSetIndex + 1, i));
        }

        // A guardian set upgrade's payload is packed as:
        //
        // | module (32) | action (1) | chain (2) | new index (4) | guardians (1) | keys (20 each) |
        //
        // Chain zero addresses it to every chain.
        Message memory upgrade = Message({
            timestamp: uint32(VM.getBlockTimestamp()),
            nonce: 0,
            emitterChainId: core.governanceChainId(),
            emitterAddress: core.governanceContract(),
            sequence: guardianSetIndex,
            consistencyLevel: 0,
            payload: abi.encodePacked(
                CORE_MODULE,
                GUARDIAN_SET_UPGRADE,
                uint16(0),
                guardianSetIndex + 1,
                uint8(guardians),
                keys
            )
        });

        core.submitNewGuardianSet(sign(upgrade, guardianSetIndex, 0, quorum(guardians)));
    }

    /// @notice Sets the fee `wormhole` charges for publishing a message on the active fork, which
    ///         on the real chain is up to Wormhole governance.
    function setMessageFee(address wormhole, uint256 messageFee) internal {
        VM.store(wormhole, bytes32(MESSAGE_FEE_SLOT), bytes32(messageFee));

        require(IWormhole(wormhole).messageFee() == messageFee, MessageFeeNotSet(wormhole));
    }

    /// @notice Number of signatures the core asks of a guardian set of `guardians`, more than two
    ///         thirds of them.
    function quorum(uint256 guardians) internal pure returns (uint256) {
        return guardians * 2 / 3 + 1;
    }

    /// @notice Hash the guardians sign and the core identifies a message by, see `body`.
    function hash(Message memory message) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(body(message))));
    }

    /// @notice Body of a message's Verifiable Message, packed as:
    ///
    ///         | timestamp (4) | nonce (4) | emitter chain (2) | emitter address (32) |
    ///         | sequence (8) | consistency level (1) | payload |
    function body(Message memory message) internal pure returns (bytes memory) {
        return abi.encodePacked(
            message.timestamp,
            message.nonce,
            message.emitterChainId,
            message.emitterAddress,
            message.sequence,
            message.consistencyLevel,
            message.payload
        );
    }

    /// @notice Signatures over a message by `count` guardians of the relayer's guardian set
    ///         `guardianSetIndex`, from guardian `first` on, each packed as:
    ///
    ///         | guardian index (1) | r (32) | s (32) | recovery id (1) |
    function signatures(
        Message memory message,
        uint32 guardianSetIndex,
        uint256 first,
        uint256 count
    ) internal pure returns (bytes memory packed) {
        bytes32 digest = hash(message);

        for (uint256 i = first; i < first + count; i++) {
            (uint8 v, bytes32 r, bytes32 s) = VM.sign(guardianKey(guardianSetIndex, i), digest);

            packed = abi.encodePacked(packed, uint8(i), r, s, v - 27);
        }
    }

    /// @notice Encodes a Verifiable Message that names guardian set `guardianSetIndex`, packed as:
    ///
    ///         | version (1) | guardian set index (4) | signatures (1) | signatures | body |
    /// @param packedSignatures Signatures as `signatures` packs them, not necessarily over this
    ///        message or by that guardian set, which is how a test forges one.
    function encode(Message memory message, uint32 guardianSetIndex, bytes memory packedSignatures)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            VERSION,
            guardianSetIndex,
            uint8(packedSignatures.length / SIGNATURE_LENGTH),
            packedSignatures,
            body(message)
        );
    }

    /// @notice Address of guardian `index` of the relayer's guardian set `guardianSetIndex`.
    function guardian(uint32 guardianSetIndex, uint256 index) internal pure returns (address) {
        return VM.addr(guardianKey(guardianSetIndex, index));
    }

    /// @dev Key of guardian `index` of the relayer's guardian set `guardianSetIndex`. Every set has
    ///      keys of its own, as a rotation on the real chain may replace any guardian.
    function guardianKey(uint32 guardianSetIndex, uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("wormhole guardian", guardianSetIndex, index)));
    }
}
