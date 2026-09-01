// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {FxEncoder} from "src/modules/fx/FxEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract FxEncoderFuzzTest is Test {
    address internal fxRoot = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    uint256 internal constant CHAIN_ID = 137;

    function testFuzzEncode(address receiverHub, uint256 chainId, uint256 callCount) public {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;

        callCount = bound(callCount, 0, 8);

        FxEncoder encoder = new FxEncoder(fxRoot);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: 0, data: abi.encode(i)});
        }

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, fxRoot);
        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testFuzzEncodeInvalidCallValue(uint256 callCount, uint256 badIndex, uint256 badValue)
        public
    {
        callCount = bound(callCount, 1, 8);
        badIndex = bound(badIndex, 0, callCount - 1);
        badValue = bound(badValue, 1, type(uint256).max);

        FxEncoder encoder = new FxEncoder(fxRoot);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({
                target: vm.addr(i + 1), value: i == badIndex ? badValue : 0, data: abi.encode(i)
            });
        }

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(fixedReceiverHub, action);
    }

    function testFuzzEncodeReceiverHubZero(uint256 chainId, uint256 callCount) public {
        callCount = bound(callCount, 0, 8);

        FxEncoder encoder = new FxEncoder(fxRoot);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }
}
