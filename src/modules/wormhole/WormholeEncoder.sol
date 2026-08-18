// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Wormhole Encoder
/// @notice Encodes messages for the Wormhole bridge.
/// @dev While Wormhole defines their own custom chain Id's, we can avoid this complication by
///      simply encoding the target chain's EIP-155 chain Id into the payload to be checked on the
///      remote chain's Decoder module.
contract WormholeEncoder is IEncoder, Owned(msg.sender) {
    /// @notice Logged when nonce for a chain is set (emergency ONLY).
    /// @param chainId Chain Id that had its nonce overwritten.
    /// @param nonce New nonce set.
    event EmergencySetNonce(uint256 indexed chainId, uint32 indexed nonce);

    /// @notice Wormhole-defined "Consistency Level".
    /// @dev We set to `1`, which means "Finalized on Ethereum".
    uint8 public constant CONSISTENCY_LEVEL = 1;

    /// @notice Wormhole core on Ethereum.
    address public immutable WORMHOLE;

    /// @notice Maps chain Id's to nonces.
    /// @dev Tracking nonces per-chain enables strict sequencing for the Wormhole Decoders.
    mapping(uint256 chainId => uint32) public nonces;

    constructor(address wormhole) {
        WORMHOLE = wormhole;
    }

    /// @notice Sets the nonce for a given chain Id directly.
    /// @dev EMERGENCY-USE ONLY.
    /// @dev This is to handle the case where a Wormhole message is dropped and the nonces otherwise
    ///      would not match.
    /// @param chainId Chain Id.
    /// @param nonce Nonce to set.
    function emergencySetNonce(uint256 chainId, uint32 nonce) public onlyOwner {
        nonces[chainId] = nonce;

        emit EmergencySetNonce(chainId, nonce);
    }

    /// @notice Encodes a multichain action for the Wormhole core.
    /// @dev The local Wormhole core is the same for all remote networks.
    /// @dev The payload contains the chain Id as well as the calls to make.
    /// @dev The receiver hub argument is ignored since a published Wormhole message is not addressed
    ///      to anyone. The Wormhole decoder is responsible for enforcing the correct receiver hub.
    /// @param multichainAction Action to send to the Receiver Hub on the remote chain.
    /// @return Bridge call(s) for SenderHub to make.
    function encode(MultichainAction calldata multichainAction, address)
        public
        returns (Call[] memory)
    {
        uint256 messageFee = IWormhole(WORMHOLE).messageFee();

        uint256 value = 0;
        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        uint32 nonce = nonces[multichainAction.chainId];

        nonces[multichainAction.chainId] = nonce + 1;

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: WORMHOLE,
            value: messageFee + value,
            data: abi.encodeCall(
                IWormhole.publishMessage,
                (
                    nonce,
                    abi.encodeCall(
                        IBridgeCalls.wormholeCall,
                        abi.encode(multichainAction.chainId, multichainAction.calls)
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        });

        return bridgeCalls;
    }
}
