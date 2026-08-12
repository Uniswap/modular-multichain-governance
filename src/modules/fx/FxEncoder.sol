// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

interface IFxRoot {
    function sendMessageToChild(address, bytes memory) external;
}

contract FxEncoder is IEncoder {
    address public immutable FX_ROOT;
    address public immutable SENDER_HUB;

    constructor(address fxRoot, address senderHub) {
        FX_ROOT = fxRoot;
        SENDER_HUB = senderHub;
    }

    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address receiverHub = ISenderHub(SENDER_HUB).receiverHubs(multichainAction.chainId);

        return (
            FX_ROOT,
            0,
            abi.encodeCall(
                IFxRoot.sendMessageToChild, (receiverHub, abi.encode(multichainAction.calls))
            )
        );
    }
}
