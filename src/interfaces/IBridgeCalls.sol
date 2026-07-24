// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Call} from "src/types/Call.sol";

interface IBridgeCalls {
    /// @dev Wormhole
    function wormholeCall(bytes memory encodedMessage) external;
    /// @dev Arbitrum Orbit
    function arbitrumCall(Call[] memory calls) external;
    /// @dev Polygon Fx
    function processMessageFromRoot(uint256 stateId, address rootMessageSender, bytes calldata data) external;
}
