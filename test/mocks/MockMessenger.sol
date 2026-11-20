// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";

contract MockMessenger is ICrossDomainMessenger {
    /// @dev Sender the real messenger holds while it is not relaying a message.
    address internal constant DEFAULT_SENDER = 0x000000000000000000000000000000000000dEaD;

    address internal _xDomainMessageSender = DEFAULT_SENDER;

    uint256 public callCount;
    address public lastTarget;
    bytes public lastMessage;
    uint32 public lastMinGasLimit;
    uint256 public lastValue;

    function setXDomainMessageSender(address sender) external {
        _xDomainMessageSender = sender;
    }

    function clearXDomainMessageSender() external {
        _xDomainMessageSender = DEFAULT_SENDER;
    }

    function sendMessage(address target, bytes memory message, uint32 minGasLimit)
        external
        payable
    {
        callCount += 1;
        lastTarget = target;
        lastMessage = message;
        lastMinGasLimit = minGasLimit;
        lastValue = msg.value;
    }

    function xDomainMessageSender() external view returns (address) {
        require(
            _xDomainMessageSender != DEFAULT_SENDER,
            "CrossDomainMessenger: xDomainMessageSender is not set"
        );

        return _xDomainMessageSender;
    }
}
