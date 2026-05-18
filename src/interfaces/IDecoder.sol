// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Call} from "src/types/Call.sol";
import {MessageType} from "src/types/MessageType.sol";

interface IDecoder {
    function decode(address bridge, bytes calldata data) external returns (MessageType, Call[] memory);
}
