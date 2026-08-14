// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IInbox} from "src/interfaces/bridges/IInbox.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Arbitrum Orbit Inbox Encoder
/// @notice Encodes messages for the Inbox bridge of Arbitrum Orbit chains.
contract InboxEncoder is Owned(msg.sender), IEncoder {
    /// @notice Logged when gas parameters are set.
    /// @param gasLimit New gas limit.
    /// @param maxFeePerGas New max fee per gas.
    /// @param maxSubmissionCost New max submission cost.
    event SetGasParameters(uint256 gasLimit, uint256 maxFeePerGas, uint256 maxSubmissionCost);

    /// @notice Logged when Arbitrum Orbit Inbox is set.
    /// @param chainId Arbitrum Orbit's chain Id.
    /// @param inbox Chain's Inbox.
    event SetInbox(uint256 indexed chainId, address indexed inbox);

    /// @notice Governance-owned timelock.
    /// @dev For gas refunds.
    address public immutable TIMELOCK;

    /// @notice Sender Hub.
    /// @dev For querying respective Receiver Hub.
    address public immutable SENDER_HUB;

    /// @notice Gas limit.
    uint256 public gasLimit;

    /// @notice Max fee per gas.
    uint256 public maxFeePerGas;

    /// @notice Max submission cost.
    uint256 public maxSubmissionCost;

    /// @notice Maps chain Id's to Arbitrum Orbit Inboxes.
    mapping(uint256 chainId => address) public inboxes;

    constructor(address timelock, address senderHub) {
        TIMELOCK = timelock;
        SENDER_HUB = senderHub;
    }

    /// @notice Sets gas parameters.
    /// @param newGasLimit New gas limit.
    /// @param newMaxFeePerGas New max fee per gas.
    /// @param newMaxSubmissionCost New max submission cost.
    function setGasParameters(
        uint256 newGasLimit,
        uint256 newMaxFeePerGas,
        uint256 newMaxSubmissionCost
    ) external onlyOwner {
        gasLimit = newGasLimit;
        maxFeePerGas = newMaxFeePerGas;
        maxSubmissionCost = newMaxSubmissionCost;

        emit SetGasParameters(newGasLimit, newMaxFeePerGas, newMaxSubmissionCost);
    }

    /// @notice Sets Arbitrum Orbit for a given chainId.
    /// @param chainId Arbitrum Orbit's chain Id.
    /// @param inbox Arbitrum Orbit chain's Inbox.
    function setInbox(uint256 chainId, address inbox) external onlyOwner {
        inboxes[chainId] = inbox;

        emit SetInbox(chainId, inbox);
    }

    /// @notice Encodes a multichain action for an Arbitrum Orbit Inbox.
    /// @dev The Inbox is unique to each Arbitrum Orbit chain.
    /// @dev The value is the sum of all call values and the gas parameters.
    /// @dev The data is an array of calls behind an `arbitrumCall` function selector.
    /// @param multichainAction Action to send to the Arbitrum Orbit chain.
    /// @return Inbox contract.
    /// @return Value to send to Inbox.
    /// @return Data to send to Inbox.
    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address inbox = inboxes[multichainAction.chainId];

        address receiverHub = ISenderHub(SENDER_HUB).receiverHubs(multichainAction.chainId);
        uint256 value = 0;

        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        value += (gasLimit * maxFeePerGas) + maxSubmissionCost;

        return (
            inbox,
            value,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    value,
                    maxSubmissionCost,
                    TIMELOCK,
                    TIMELOCK,
                    gasLimit,
                    maxFeePerGas,
                    abi.encodeCall(IBridgeCalls.arbitrumCall, (multichainAction.calls))
                )
            )
        );
    }
}
