// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {MultichainAction} from "src/types/MultichainAction.sol";

interface IEncoder {
    function encode(MultichainAction calldata multichainAction)
        external
        returns (address, uint256, bytes memory);
}
