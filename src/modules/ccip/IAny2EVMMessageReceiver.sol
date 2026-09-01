// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Any2EVMMessage} from "src/modules/ccip/IRouterClient.sol";

interface IAny2EVMMessageReceiver {
    /// @notice Called by the Router to deliver a message.
    /// @dev A failed message can be manually executed.
    /// @param message CCIP Message.
    /// @dev Note ensure you check the msg.sender is the Router.
    function ccipReceive(Any2EVMMessage calldata message) external;
}
