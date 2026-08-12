// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Call} from "src/types/Call.sol";

struct MultichainAction {
    uint256 chainId;
    Call[] calls;
}
