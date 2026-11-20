// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {FxEncoder} from "src/modules/fx/FxEncoder.sol";
import {FxError} from "src/modules/fx/FxError.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract FxEncoderTest is Test {
    FxEncoder internal encoder;

    address internal bob = vm.addr(1);
    address internal fxRoot = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal callTargetA = vm.addr(4);
    address internal callTargetB = vm.addr(5);
    address internal callTargetC = vm.addr(6);

    uint256 internal constant CHAIN_ID = 137;
    uint256 internal constant OTHER_CHAIN_ID = 8453;

    uint256 internal constant CALL_VALUE = 1 ether;

    uint256 internal constant MAX_STATE_SYNC_SIZE = 30_000;

    // Byte length of the state sync for one call without data, and the longest data that keeps
    // the state sync for one call within the maximum. State sync lengths are multiples of a word,
    // the longest that fits is 29,984 bytes.
    uint256 internal constant EMPTY_CALL_STATE_SYNC_SIZE = 352;
    uint256 internal constant MAX_CALL_DATA_LENGTH = 29_632;

    // Calls without data, each 160 bytes of a state sync that is 192 bytes without calls, that
    // fill the largest state sync that fits.
    uint256 internal constant MAX_EMPTY_CALLS = 186;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"03";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        encoder = new FxEncoder(fxRoot);
    }

    function testConstructor() public {
        FxEncoder fresh = new FxEncoder(fxRoot);

        assertEq(fresh.FX_ROOT(), fxRoot);
        assertEq(fresh.MAX_STATE_SYNC_SIZE(), MAX_STATE_SYNC_SIZE);

        (bool success, bytes memory returnData) =
            address(fresh).call(abi.encodeWithSignature("owner()"));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testEncode() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, fxRoot);
        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeReceiverHubZero() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeInvalidCallValue() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 1, data: CALL_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueLastCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: CALL_VALUE, data: THIRD_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueMiddleCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: CALL_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: THIRD_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeAllZeroCallValues() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: THIRD_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeEmptyCalls() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, fxRoot);
        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeCheckOrder() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: CALL_VALUE, data: CALL_DATA});

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeMultipleCalls() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeDataAtMaximum() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] =
            Call({target: callTargetA, value: 0, data: new bytes(MAX_CALL_DATA_LENGTH)});

        bytes memory stateSync = abi.encode(address(this), receiverHub, abi.encode(action.calls));

        assertEq(stateSync.length, EMPTY_CALL_STATE_SYNC_SIZE + MAX_CALL_DATA_LENGTH);
        assertLe(stateSync.length, MAX_STATE_SYNC_SIZE);
        assertGt(stateSync.length + 32, MAX_STATE_SYNC_SIZE);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeDataTooLarge() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] =
            Call({target: callTargetA, value: 0, data: new bytes(MAX_CALL_DATA_LENGTH + 1)});

        bytes memory stateSync = abi.encode(address(this), receiverHub, abi.encode(action.calls));

        assertEq(stateSync.length, EMPTY_CALL_STATE_SYNC_SIZE + MAX_CALL_DATA_LENGTH + 32);
        assertGt(stateSync.length, MAX_STATE_SYNC_SIZE);

        vm.expectRevert(FxError.StateSyncTooLarge.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeCallsAtMaximum() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](MAX_EMPTY_CALLS);
        for (uint256 i; i < MAX_EMPTY_CALLS; i++) {
            action.calls[i] = Call({target: callTargetA, value: 0, data: ""});
        }

        bytes memory stateSync = abi.encode(address(this), receiverHub, abi.encode(action.calls));

        assertLe(stateSync.length, MAX_STATE_SYNC_SIZE);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IFxRoot.sendMessageToChild, (receiverHub, abi.encode(action.calls)))
        );
    }

    function testEncodeCallsTooLarge() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](MAX_EMPTY_CALLS + 1);
        for (uint256 i; i < MAX_EMPTY_CALLS + 1; i++) {
            action.calls[i] = Call({target: callTargetA, value: 0, data: ""});
        }

        bytes memory stateSync = abi.encode(address(this), receiverHub, abi.encode(action.calls));

        assertGt(stateSync.length, MAX_STATE_SYNC_SIZE);

        vm.expectRevert(FxError.StateSyncTooLarge.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeDataTooLargeCheckOrder() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({
            target: callTargetA, value: CALL_VALUE, data: new bytes(MAX_CALL_DATA_LENGTH + 1)
        });

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeChainIdIgnored() public view {
        MultichainAction memory actionA;
        actionA.chainId = CHAIN_ID;
        actionA.calls = new Call[](1);
        actionA.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        MultichainAction memory actionB;
        actionB.chainId = OTHER_CHAIN_ID;
        actionB.calls = new Call[](1);
        actionB.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        Call[] memory bridgeCallsA = encoder.encode(receiverHub, actionA);
        Call[] memory bridgeCallsB = encoder.encode(receiverHub, actionB);

        assertEq(bridgeCallsA[0].target, fxRoot);
        assertEq(bridgeCallsB[0].target, fxRoot);
        assertEq(bridgeCallsA[0].value, bridgeCallsB[0].value);
        assertEq(bridgeCallsA[0].data, bridgeCallsB[0].data);
    }

    function testEncodeAnyCaller() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, fxRoot);
    }
}
