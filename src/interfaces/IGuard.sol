// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Call} from "src/types/Call.sol";

interface IGuard {
    function commitCalls(address bridge, Call[] calldata calls) external;

    function authorizeCalls(bytes32 callsHash) external;
}
