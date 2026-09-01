// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {SenderHub} from "src/SenderHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockEncoder} from "test/mocks/MockEncoder.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";

contract SenderHubFuzzTest is Test {
    address internal admin = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    uint256 internal constant CHAIN_ID = 8453;

    function testFuzzSetEncoder(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        address encoder
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        SenderHub senderHub = new SenderHub();

        assertEq(senderHub.owner(), owner);

        if (caller == owner) {
            vm.expectEmit(address(senderHub));
            emit ISenderHub.SetEncoder(chainId, encoder);

            vm.prank(caller);
            senderHub.setEncoder(chainId, encoder);

            assertEq(senderHub.encoders(chainId), encoder);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            senderHub.setEncoder(chainId, encoder);

            assertEq(senderHub.encoders(chainId), address(0x00));
        }
    }

    function testFuzzSetReceiverHub(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        address receiverHub
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        SenderHub senderHub = new SenderHub();

        if (caller == owner) {
            vm.expectEmit(address(senderHub));
            emit ISenderHub.SetReceiverHub(chainId, receiverHub);

            vm.prank(caller);
            senderHub.setReceiverHub(chainId, receiverHub);

            assertEq(senderHub.receiverHubs(chainId), receiverHub);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            senderHub.setReceiverHub(chainId, receiverHub);

            assertEq(senderHub.receiverHubs(chainId), address(0x00));
        }
    }

    function testFuzzSendMultichainActions(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        uint256 callCount,
        uint256 value
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);
        value = bound(value, 0, 100 ether);

        vm.prank(owner);
        SenderHub senderHub = new SenderHub();

        MockEncoder encoder = new MockEncoder();
        MockTarget bridge = new MockTarget();

        vm.prank(owner);
        senderHub.setEncoder(chainId, address(encoder));

        vm.prank(owner);
        senderHub.setReceiverHub(chainId, fixedReceiverHub);

        Call[] memory bridgeCalls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            bridgeCalls[i] = Call({target: address(bridge), value: 0, data: abi.encode(i)});
        }
        encoder.setReturnCalls(bridgeCalls);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = chainId;
        actions[0].calls = new Call[](0);

        vm.deal(caller, value);
        vm.deal(address(this), value);

        if (caller == owner) {
            vm.prank(caller);
            senderHub.sendMultichainActions{value: value}(actions);

            assertEq(encoder.encodeCount(), 1);
            assertEq(encoder.lastChainId(), chainId);
            assertEq(bridge.callCount(), callCount);
            assertEq(address(senderHub).balance, value);

            for (uint256 i; i < callCount; i++) {
                assertEq(bridge.dataAt(i), abi.encode(i));
            }
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            senderHub.sendMultichainActions{value: value}(actions);

            assertEq(encoder.encodeCount(), 0);
            assertEq(bridge.callCount(), 0);
            assertEq(address(senderHub).balance, 0);
        }
    }

    function testFuzzSendMultichainActionsValueAccounting(
        uint256[8] calldata callValues,
        uint256 msgValue
    ) public {
        vm.prank(admin);
        SenderHub senderHub = new SenderHub();

        MockEncoder encoder = new MockEncoder();
        MockTarget bridge = new MockTarget();

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, fixedReceiverHub);

        Call[] memory bridgeCalls = new Call[](8);
        uint256 totalForwarded;
        for (uint256 i; i < 8; i++) {
            uint256 callValue = bound(callValues[i], 0, 10 ether);
            totalForwarded += callValue;
            bridgeCalls[i] = Call({target: address(bridge), value: callValue, data: abi.encode(i)});
        }
        encoder.setReturnCalls(bridgeCalls);

        msgValue = bound(msgValue, totalForwarded, totalForwarded + 100 ether);

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0].chainId = CHAIN_ID;
        actions[0].calls = new Call[](0);

        vm.deal(admin, msgValue);

        vm.prank(admin);
        senderHub.sendMultichainActions{value: msgValue}(actions);

        assertEq(address(bridge).balance, totalForwarded);
        assertEq(address(senderHub).balance, msgValue - totalForwarded);
        assertEq(totalForwarded, msgValue - address(senderHub).balance);
    }

    function testFuzzSendMultichainActionsBridgeCallFail(
        address bridge,
        uint256 value,
        bytes calldata data
    ) public {
        vm.assume(bridge != VM_ADDRESS);

        value = bound(value, 1, type(uint256).max);

        vm.prank(admin);
        SenderHub senderHub = new SenderHub();

        MockEncoder encoder = new MockEncoder();

        vm.prank(admin);
        senderHub.setEncoder(CHAIN_ID, address(encoder));

        vm.prank(admin);
        senderHub.setReceiverHub(CHAIN_ID, fixedReceiverHub);

        Call[] memory bridgeCalls = new Call[](1);
        bridgeCalls[0] = Call({target: bridge, value: value, data: data});
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
            returnData, abi.encodeWithSelector(ISenderHub.CallFail.selector, bridge, bytes(""))
        );
    }
}
