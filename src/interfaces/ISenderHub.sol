// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {MultichainAction} from "src/types/MultichainAction.sol";

interface ISenderHub {
    function encoders(uint256 chainId) external view returns (address);
    function receiverHubs(uint256 chainId) external view returns (address);
    function setEncoders(uint256[] calldata chainIds, address[] calldata encoders) external;
    function setReceiverHubs(uint256[] calldata chainIds, address[] calldata receiverHubs) external;
    function sendMultichainActions(MultichainAction[] calldata actions) external;
}
