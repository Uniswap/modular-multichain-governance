// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {EVM2AnyMessage, EVMTokenAmount, IRouterClient} from "src/modules/ccip/IRouterClient.sol";

contract MockRouter is IRouterClient {
    uint256 public fee;
    bool public feeShouldRevert;
    bytes public feeRevertData;

    uint256 public sendCount;
    uint64 public lastSendChainSelector;
    uint256 public lastValue;
    EVM2AnyMessage internal _lastMessage;

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function setFeeRevert(bool revert_, bytes memory data) external {
        feeShouldRevert = revert_;
        feeRevertData = data;
    }

    function lastMessage() external view returns (EVM2AnyMessage memory) {
        return _lastMessage;
    }

    function getFee(uint64, EVM2AnyMessage calldata) external view returns (uint256) {
        if (feeShouldRevert) {
            bytes memory rd = feeRevertData;
            if (rd.length == 0) revert();
            assembly {
                revert(add(rd, 0x20), mload(rd))
            }
        }

        return fee;
    }

    function ccipSend(uint64 targetChainSelector, EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        sendCount += 1;
        lastSendChainSelector = targetChainSelector;
        lastValue = msg.value;

        _lastMessage.receiver = message.receiver;
        _lastMessage.data = message.data;
        _lastMessage.feeToken = message.feeToken;
        _lastMessage.extraArgs = message.extraArgs;

        delete _lastMessage.tokenAmounts;
        for (uint256 i; i < message.tokenAmounts.length; i++) {
            _lastMessage.tokenAmounts
                .push(
                    EVMTokenAmount({
                        token: message.tokenAmounts[i].token, amount: message.tokenAmounts[i].amount
                    })
                );
        }

        return bytes32(sendCount);
    }
}
