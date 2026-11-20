// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed Wormhole core used by the fork tests, beyond what the modules
///         themselves depend on (see `src/interfaces/bridges/IWormhole.sol`).
interface IWormholeCore {
    /// @dev Guardians whose signatures the core accepts.
    /// @param keys Guardian addresses, a signature names its guardian by index.
    /// @param expirationTime Zero for the current set, for a replaced one the time until which
    ///        its signatures are still accepted.
    struct GuardianSet {
        address[] keys;
        uint32 expirationTime;
    }

    /// @notice Logged for every published message, this is what the guardians observe and sign.
    /// @param sender Caller of `publishMessage`, the message's emitter.
    /// @param sequence Number of messages the emitter published before this one.
    /// @param nonce Nonce the emitter passed.
    /// @param payload Payload the emitter passed.
    /// @param consistencyLevel Finality the guardians wait for before signing.
    event LogMessagePublished(
        address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel
    );

    /// @notice Wormhole-defined id of the chain the core is on, not its EIP-155 chain id.
    function chainId() external view returns (uint16);

    /// @notice Wormhole-defined id of the chain governance messages are emitted on.
    function governanceChainId() external view returns (uint16);

    /// @notice Emitter of governance messages.
    function governanceContract() external view returns (bytes32);

    /// @notice Index of the guardian set new messages are signed by.
    function getCurrentGuardianSetIndex() external view returns (uint32);

    /// @notice Guardian set at `index`, empty if there is none.
    function getGuardianSet(uint32 index) external view returns (GuardianSet memory);

    /// @notice Sequence number the next message of `emitter` gets.
    function nextSequence(address emitter) external view returns (uint64);

    /// @notice Replaces the guardian set with the one in a governance message signed by the
    ///         current set. The replaced set's signatures are accepted for another day.
    function submitNewGuardianSet(bytes memory encodedVM) external;
}
