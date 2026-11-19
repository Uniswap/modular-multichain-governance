// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {FxEncoder} from "src/modules/fx/FxEncoder.sol";
import {FxError} from "src/modules/fx/FxError.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract FxEncoderFuzzTest is Test {
    address internal fxRoot = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    uint256 internal constant CHAIN_ID = 137;

    uint256 internal constant MAX_STATE_SYNC_SIZE = 30_000;

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

    function testFuzzEncodeStateSyncSize(uint256 callCount, uint256 dataLength) public {
        callCount = bound(callCount, 1, 8);
        dataLength = bound(dataLength, 0, 8000);

        FxEncoder encoder = new FxEncoder(fxRoot);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: 0, data: new bytes(dataLength)});
        }

        // The state sync is 192 bytes without calls, and each call adds 160 bytes and its data,
        // padded to a word.
        uint256 stateSyncSize = 192 + (callCount * (160 + ((dataLength + 31) / 32) * 32));

        assertEq(
            abi.encode(address(this), fixedReceiverHub, abi.encode(action.calls)).length,
            stateSyncSize
        );

        if (stateSyncSize > MAX_STATE_SYNC_SIZE) {
            vm.expectRevert(FxError.StateSyncTooLarge.selector);
            encoder.encode(fixedReceiverHub, action);
        } else {
            Call[] memory bridgeCalls = encoder.encode(fixedReceiverHub, action);

            assertEq(
                bridgeCalls[0].data,
                abi.encodeCall(
                    IFxRoot.sendMessageToChild, (fixedReceiverHub, abi.encode(action.calls))
                )
            );
        }
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
