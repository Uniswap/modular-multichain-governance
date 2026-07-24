// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {Constants} from "./Constants.sol";
import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

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
    address public immutable BRIDGE_REGISTRY;
    address public immutable TIMELOCK;

    GasConfig public gasConfig;
    mapping(uint256 => address) public arbitrumOrbitInbox;

    constructor(address bridgeRegistry, address timelock) {
        BRIDGE_REGISTRY = bridgeRegistry;
        TIMELOCK = timelock;
    }

    function setGasConfig(GasConfig memory config) external {
        gasConfig = config;
    }

    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address inbox = arbitrumOrbitInbox[multichainAction.chainId];

        address target = BridgeRegistry(BRIDGE_REGISTRY).receiverHubs(multichainAction.bridgeId);
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
                    target,
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
