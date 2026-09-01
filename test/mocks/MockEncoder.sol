// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract MockEncoder is IEncoder {
    Call[] internal _returnCalls;
    Call[] internal _lastCalls;

    bool public shouldRevert;
    bytes public revertData;

    uint256 public encodeCount;
    address public lastReceiverHub;
    uint256 public lastChainId;

    function setReturnCalls(Call[] memory calls) external {
        delete _returnCalls;
        for (uint256 i; i < calls.length; i++) {
            _returnCalls.push(
                Call({target: calls[i].target, value: calls[i].value, data: calls[i].data})
            );
        }
    }

    function setRevert(bool revert_, bytes memory data) external {
        shouldRevert = revert_;
        revertData = data;
    }

    function returnCalls() external view returns (Call[] memory) {
        return _returnCalls;
    }

    function lastCalls() external view returns (Call[] memory) {
        return _lastCalls;
    }

    function encode(address receiverHub, MultichainAction calldata multichainAction)
        external
        returns (Call[] memory)
    {
        if (shouldRevert) {
            bytes memory data = revertData;
            if (data.length == 0) revert();
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }

        encodeCount += 1;
        lastReceiverHub = receiverHub;
        lastChainId = multichainAction.chainId;

        delete _lastCalls;
        for (uint256 i; i < multichainAction.calls.length; i++) {
            _lastCalls.push(
                Call({
                    target: multichainAction.calls[i].target,
                    value: multichainAction.calls[i].value,
                    data: multichainAction.calls[i].data
                })
            );
        }

        return _returnCalls;
    }
}
