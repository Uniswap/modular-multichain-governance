// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

interface IFxRoot {
    function sendMessageToChild(address, bytes memory) external;
}

contract FxEncoder is IEncoder {
    address public immutable FX_ROOT;
    address public immutable BRIDGE_REGISTRY;

    constructor(address fxRoot, address bridgeRegistry) {
        FX_ROOT = fxRoot;
        BRIDGE_REGISTRY = bridgeRegistry;
    }

    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address receiverHub = BridgeRegistry(BRIDGE_REGISTRY).receiverHubs(multichainAction.bridgeId);

        return (
            FX_ROOT,
            0,
            abi.encodeCall(
                IFxRoot.sendMessageToChild, (receiverHub, abi.encode(multichainAction.calls))
            )
        );
    }
}
