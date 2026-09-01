// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";

contract MockDecoder is IDecoder {
    Call[] internal _returnCalls;

    bool public shouldRevert;
    bytes public revertData;

    uint256 public decodeCount;
    address public lastCaller;
    bytes public lastData;

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

    function decode(address caller, bytes calldata data) external returns (Call[] memory) {
        if (shouldRevert) {
            bytes memory rd = revertData;
            if (rd.length == 0) revert();
            assembly {
                revert(add(rd, 0x20), mload(rd))
            }
        }

        decodeCount += 1;
        lastCaller = caller;
        lastData = data;

        return _returnCalls;
    }
}
