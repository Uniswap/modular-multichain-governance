// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Call} from "src/types/Call.sol";
import {MessageType} from "src/types/MessageType.sol";

struct MultichainAction {
    MessageType messageType;
    uint256 chainId;
    bytes32 bridgeId;
    Call[] calls;
}
