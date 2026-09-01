// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {SenderHub} from "src/SenderHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockEncoder} from "test/mocks/MockEncoder.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";

contract SenderHubTest is Test {
    SenderHub internal senderHub;
    MockEncoder internal encoder;
    MockTarget internal bridge;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal otherReceiverHub = vm.addr(4);
    address internal thirdReceiverHub = vm.addr(5);
    address internal actionTarget = vm.addr(6);
    address internal encoderEoa = vm.addr(7);

    uint256 internal constant CHAIN_ID = 8453;
    uint256 internal constant OTHER_CHAIN_ID = 42161;
    uint256 internal constant THIRD_CHAIN_ID = 137;

    uint256 internal constant FUNDING = 10 ether;
    uint256 internal constant BRIDGE_VALUE = 1 ether;
    uint256 internal constant SPENT_VALUE = 0.4 ether;

    bytes internal constant BRIDGE_DATA = hex"c0ffee";
    bytes internal constant ACTION_DATA = hex"dead";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"02";
    bytes internal constant THIRD_DATA = hex"03";

    function setUp() public {
        vm.prank(admin);
        senderHub = new SenderHub();

        encoder = new MockEncoder();
        bridge = new MockTarget();
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        SenderHub fresh = new SenderHub();

        assertEq(fresh.owner(), admin);
    }

    function testSetEncoder() public {
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        assertEq(senderHub.encoders(CHAIN_ID), address(encoder));
    }

    function testSetEncoderOverwrite() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        MockEncoder second = new MockEncoder();

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetEncoder(CHAIN_ID, address(second));

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(second));

        assertEq(senderHub.encoders(CHAIN_ID), address(second));
    }

    function testSetEncoderZeroAddress() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetEncoder(CHAIN_ID, address(0x00));

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(0x00));

        assertEq(senderHub.encoders(CHAIN_ID), address(0x00));
    }

    function testSetEncoderNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        assertEq(senderHub.encoders(CHAIN_ID), address(0x00));
    }

    function testSetReceiverHub() public {
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetReceiverHub(CHAIN_ID, receiverHub);

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        assertEq(senderHub.receiverHubs(CHAIN_ID), receiverHub);
    }

    function testSetReceiverHubOverwrite() public {
        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetReceiverHub(CHAIN_ID, otherReceiverHub);

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, otherReceiverHub);

        assertEq(senderHub.receiverHubs(CHAIN_ID), otherReceiverHub);
    }

    function testSetReceiverHubZeroAddress() public {
        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SetReceiverHub(CHAIN_ID, address(0x00));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, address(0x00));

        assertEq(senderHub.receiverHubs(CHAIN_ID), address(0x00));
    }

    function testSetReceiverHubNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        assertEq(senderHub.receiverHubs(CHAIN_ID), address(0x00));
    }

    function testSendMultichainActions() public {
        vm.deal(admin, FUNDING);

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: BRIDGE_VALUE, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](1);
        actions[0].calls[0] = Call({target: actionTarget, value: BRIDGE_VALUE, data: ACTION_DATA});

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions{value: BRIDGE_VALUE}(actions);

        assertEq(encoder.encodeCount(), 1);
        assertEq(encoder.lastReceiverHub(), receiverHub);
        assertEq(encoder.lastChainId(), CHAIN_ID);
        assertEq(bridge.callCount(), 1);
        assertEq(bridge.dataAt(0), BRIDGE_DATA);
        assertEq(bridge.valueAt(0), BRIDGE_VALUE);
        assertEq(address(bridge).balance, BRIDGE_VALUE);
    }

    function testSendMultichainActionsEmptyActions() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        MultichainAction[] memory actions = new MultichainAction[](0);

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(encoder.encodeCount(), 0);
        assertEq(bridge.callCount(), 0);
    }

    function testSendMultichainActionsEmptyBridgeCalls() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        encoder.setReturnCalls(new Call[](0));

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(encoder.encodeCount(), 1);
        assertEq(bridge.callCount(), 0);
    }

    function testSendMultichainActionsMultipleBridgeCalls() public {
        vm.deal(admin, FUNDING);

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](3);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: FIRST_DATA});
        bridgeCalls[1] = Call({target: address(bridge), value: BRIDGE_VALUE, data: SECOND_DATA});
        bridgeCalls[2] = Call({target: address(bridge), value: 2 * BRIDGE_VALUE, data: THIRD_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions{value: 3 * BRIDGE_VALUE}(actions);

        assertEq(bridge.callCount(), 3);
        assertEq(bridge.dataAt(0), FIRST_DATA);
        assertEq(bridge.dataAt(1), SECOND_DATA);
        assertEq(bridge.dataAt(2), THIRD_DATA);
        assertEq(bridge.valueAt(0), 0);
        assertEq(bridge.valueAt(1), BRIDGE_VALUE);
        assertEq(bridge.valueAt(2), 2 * BRIDGE_VALUE);
    }

    function testSendMultichainActionsMultipleActions() public {
        MockEncoder encoderB = new MockEncoder();
        MockEncoder encoderC = new MockEncoder();
        MockTarget bridgeB = new MockTarget();
        MockTarget bridgeC = new MockTarget();

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setEncoder(OTHER_CHAIN_ID, address(encoderB));

        vm.prank(admin);
        senderHub.setEncoder(THIRD_CHAIN_ID, address(encoderC));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        vm.prank(admin);
        senderHub.setReceiverHub(OTHER_CHAIN_ID, otherReceiverHub);

        vm.prank(admin);
        senderHub.setReceiverHub(THIRD_CHAIN_ID, thirdReceiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: FIRST_DATA});
        encoder.setReturnCalls(bridgeCalls);
        bridgeCalls[0] = Call({target: address(bridgeB), value: 0, data: SECOND_DATA});
        encoderB.setReturnCalls(bridgeCalls);
        bridgeCalls[0] = Call({target: address(bridgeC), value: 0, data: THIRD_DATA});
        encoderC.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](3);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);
        actions[1].chainId = OTHER_CHAIN_ID;
        actions[1].calls = new Call[](0);
        actions[2].chainId = THIRD_CHAIN_ID;
        actions[2].calls = new Call[](0);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(OTHER_CHAIN_ID, address(bridgeB), address(encoderB));
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(THIRD_CHAIN_ID, address(bridgeC), address(encoderC));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        assertEq(encoder.lastReceiverHub(), receiverHub);
        assertEq(encoderB.lastReceiverHub(), otherReceiverHub);
        assertEq(encoderC.lastReceiverHub(), thirdReceiverHub);
        assertEq(bridge.dataAt(0), FIRST_DATA);
        assertEq(bridgeB.dataAt(0), SECOND_DATA);
        assertEq(bridgeC.dataAt(0), THIRD_DATA);
    }

    function testSendMultichainActionsSameChainIdTwice() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](2);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);
        actions[1].chainId = CHAIN_ID;
        actions[1].calls = new Call[](0);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));
        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(CHAIN_ID, address(bridge), address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        assertEq(encoder.encodeCount(), 2);
        assertEq(bridge.callCount(), 2);
    }

    function testSendMultichainActionsEncoderNotSet() public {
        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        assertEq(senderHub.encoders(CHAIN_ID), address(0x00));

        vm.prank(admin);
        (bool success, bytes memory returnData) =
            address(senderHub).call(abi.encodeCall(SenderHub.sendMultichainActions, (actions)));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testSendMultichainActionsReceiverHubNotSet() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        encoder.setReturnCalls(new Call[](0));

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        assertEq(encoder.lastReceiverHub(), address(0x00));
        assertEq(encoder.encodeCount(), 1);
    }

    function testSendMultichainActionsEncoderReverts() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        encoder.setRevert(true, abi.encodeWithSelector(IEncoder.InvalidCallValue.selector));

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(admin);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        senderHub.sendMultichainActions(actions);
    }

    function testSendMultichainActionsEncoderNotAContract() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, encoderEoa);

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        assertEq(encoderEoa.code.length, 0);

        vm.prank(admin);
        (bool success, bytes memory returnData) =
            address(senderHub).call(abi.encodeCall(SenderHub.sendMultichainActions, (actions)));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testSendMultichainActionsBridgeCallReverts() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        bridge.setRevert(true);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(admin);
        (bool success, bytes memory returnData) =
            address(senderHub).call(abi.encodeCall(SenderHub.sendMultichainActions, (actions)));

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                address(bridge),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, uint256(0))
            )
        );
    }

    function testSendMultichainActionsInsufficientValue() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: BRIDGE_VALUE, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        assertEq(address(senderHub).balance, 0);

        vm.prank(admin);
        (bool success, bytes memory returnData) =
            address(senderHub).call(abi.encodeCall(SenderHub.sendMultichainActions, (actions)));

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(ISenderHub.CallFail.selector, address(bridge), bytes(""))
        );
        assertEq(bridge.callCount(), 0);
    }

    function testSendMultichainActionsExcessValue() public {
        vm.deal(admin, FUNDING);

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: SPENT_VALUE, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(admin);
        senderHub.sendMultichainActions{value: BRIDGE_VALUE}(actions);

        assertEq(address(bridge).balance, SPENT_VALUE);
        assertEq(address(senderHub).balance, BRIDGE_VALUE - SPENT_VALUE);
    }

    function testSendMultichainActionsZeroValue() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(admin);
        senderHub.sendMultichainActions{value: 0}(actions);

        assertEq(bridge.callCount(), 1);
        assertEq(bridge.valueAt(0), 0);
        assertEq(address(senderHub).balance, 0);
    }

    function testSendMultichainActionsNotOwner() public {
        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        senderHub.sendMultichainActions(actions);

        assertEq(bridge.callCount(), 0);
        assertEq(encoder.encodeCount(), 0);
    }

    function testSendMultichainActionsNotOwnerWithValue() public {
        vm.deal(bob, FUNDING);

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, receiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: address(bridge), value: 0, data: BRIDGE_DATA});
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        senderHub.sendMultichainActions{value: BRIDGE_VALUE}(actions);

        assertEq(bridge.callCount(), 0);
        assertEq(encoder.encodeCount(), 0);
        assertEq(address(senderHub).balance, 0);
    }

    function testEncodersDefault() public view {
        assertEq(senderHub.encoders(0), address(0x00));
        assertEq(senderHub.encoders(CHAIN_ID), address(0x00));
        assertEq(senderHub.encoders(type(uint256).max), address(0x00));
    }

    function testReceiverHubsDefault() public view {
        assertEq(senderHub.receiverHubs(0), address(0x00));
        assertEq(senderHub.receiverHubs(CHAIN_ID), address(0x00));
        assertEq(senderHub.receiverHubs(type(uint256).max), address(0x00));
    }
}
