// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IDecoder} from "src/interfaces/IDecoder.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MessageType} from "src/types/MessageType.sol";
import {Call} from "src/types/Call.sol";

contract WormholeDecoder is IDecoder {
    function decode(address bridge, bytes calldata data) external returns (MessageType, Call[] memory) {
        
    }
}
