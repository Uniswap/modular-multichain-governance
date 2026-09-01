// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";

contract MockFxRoot is IFxRoot {
    uint256 public callCount;
    address public lastTarget;
    bytes public lastData;

    function sendMessageToChild(address target, bytes memory data) external {
        callCount += 1;
        lastTarget = target;
        lastData = data;
    }
}
