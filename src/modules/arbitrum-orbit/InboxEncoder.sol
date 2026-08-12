// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

// import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";

interface IInbox {
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes memory data
    ) external payable returns (uint256);
}

struct GasConfig {
    uint256 gasLimit;
    uint256 maxFeePerGas;
    uint256 maxSubmissionCost;
}

contract InboxEncoder is IEncoder {
    address public immutable TIMELOCK;
    address public immutable SENDER_HUB;

    GasConfig public gasConfig;
    mapping(uint256 => address) public arbitrumOrbitInboxes;

    constructor(address timelock, address senderHub) {
        TIMELOCK = timelock;
        SENDER_HUB = senderHub;
    }

    function setGasConfig(GasConfig memory config) external {
        gasConfig = config;
    }

    function setArbitrumOrbitInbox(uint256 chainId, address arbitrumOrbitInbox) external {
        arbitrumOrbitInboxes[chainId] = arbitrumOrbitInbox;
    }

    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address inbox = arbitrumOrbitInboxes[multichainAction.chainId];

        address receiverHub = ISenderHub(SENDER_HUB).receiverHubs(multichainAction.chainId);
        uint256 value = 0;

        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        return (
            inbox,
            (gasConfig.gasLimit * gasConfig.maxFeePerGas) + gasConfig.maxSubmissionCost + value,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    value,
                    gasConfig.maxSubmissionCost,
                    TIMELOCK,
                    TIMELOCK,
                    gasConfig.gasLimit,
                    gasConfig.maxFeePerGas,
                    abi.encodeCall(IBridgeCalls.arbitrumCall, (multichainAction.calls))
                )
            )
        );
    }
}
