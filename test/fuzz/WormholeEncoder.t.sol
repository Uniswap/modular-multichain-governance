// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {WormholeEncoder} from "src/modules/wormhole/WormholeEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockWormhole} from "test/mocks/MockWormhole.sol";

contract WormholeEncoderFuzzTest is Test {
    function testFuzzEncode(
        address senderHub,
        address receiverHub,
        uint256 chainId,
        uint256 messageFee,
        uint256 lastMessageId,
        uint256 callCount
    ) public {
        messageFee = bound(messageFee, 0, 100 ether);
        lastMessageId = bound(lastMessageId, 0, type(uint256).max - 1);
        callCount = bound(callCount, 0, 8);

        MockWormhole wormhole = new MockWormhole();
        wormhole.setMessageFee(messageFee);

        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        // `messageId` is the only mutable storage variable on the encoder, so it occupies slot 0.
        vm.store(address(encoder), bytes32(0), bytes32(lastMessageId));

        assertEq(encoder.messageId(), lastMessageId);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);

        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: 0, data: abi.encode(i)});
        }

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, address(wormhole));
        assertEq(bridgeCalls[0].value, messageFee);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (uint32(0), abi.encode(lastMessageId + 1, chainId, action.calls), uint8(1))
            )
        );
        assertEq(encoder.messageId(), lastMessageId + 1);
    }

    function testFuzzEncodeMessageIdSharedAcrossChains(
        address senderHub,
        address receiverHub,
        uint256[] calldata chainIds
    ) public {
        uint256 messageCount = bound(chainIds.length, 0, 8);

        MockWormhole wormhole = new MockWormhole();
        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        MultichainAction memory action;
        action.calls = new Call[](0);

        for (uint256 i; i < messageCount; i++) {
            action.chainId = chainIds[i];

            vm.prank(senderHub);
            Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

            assertEq(
                bridgeCalls[0].data,
                abi.encodeCall(
                    IWormhole.publishMessage,
                    (uint32(0), abi.encode(i + 1, chainIds[i], action.calls), uint8(1))
                )
            );
            assertEq(encoder.messageId(), i + 1);
        }
    }

    function testFuzzEncodeInvalidCallValue(
        address senderHub,
        address receiverHub,
        uint256 chainId,
        uint256 callCount,
        uint256 badIndex,
        uint256 badValue
    ) public {
        callCount = bound(callCount, 1, 8);
        badIndex = bound(badIndex, 0, callCount - 1);
        badValue = bound(badValue, 1, type(uint256).max);

        MockWormhole wormhole = new MockWormhole();

        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({
                target: vm.addr(i + 1), value: i == badIndex ? badValue : 0, data: abi.encode(i)
            });
        }

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.messageId(), 0);
    }

    function testFuzzEncodeCallerNotSenderHub(
        address senderHub,
        address receiverHub,
        address caller,
        bool callerIsSenderHub,
        uint256 chainId
    ) public {
        if (callerIsSenderHub) caller = senderHub;
        else if (caller == senderHub) caller = address(uint160(caller) ^ 1);

        vm.assume(senderHub != VM_ADDRESS && caller != VM_ADDRESS);

        MockWormhole wormhole = new MockWormhole();
        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](0);

        vm.prank(caller);
        (bool success, bytes memory returnData) =
            address(encoder).call(abi.encodeCall(WormholeEncoder.encode, (receiverHub, action)));

        if (caller == senderHub) {
            assertTrue(success);
            assertEq(encoder.messageId(), 1);
        } else {
            assertFalse(success);
            assertEq(returnData, abi.encodeWithSelector(IEncoder.NotSenderHub.selector));
            assertEq(encoder.messageId(), 0);
        }
    }
}
