// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

interface IDecoder {
    function decode(address caller, bytes calldata data) external returns (Call[] memory);
}
