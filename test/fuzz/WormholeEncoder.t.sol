// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeEncoder} from "src/modules/wormhole/WormholeEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockWormhole} from "test/mocks/MockWormhole.sol";

contract WormholeEncoderFuzzTest is Test {
    address internal admin = vm.addr(102);

    function testFuzzEmergencySetNonce(
        address senderHub,
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        uint32 nonce
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        MockWormhole wormhole = new MockWormhole();

        vm.prank(owner);
        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit WormholeEncoder.EmergencySetNonce(chainId, nonce);

            vm.prank(caller);
            encoder.emergencySetNonce(chainId, nonce);

            assertEq(encoder.nonces(chainId), nonce);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.emergencySetNonce(chainId, nonce);

            assertEq(encoder.nonces(chainId), 0);
        }
    }

    function testFuzzEncode(
        address senderHub,
        address receiverHub,
        uint256 chainId,
        uint256 messageFee,
        uint32 startNonce,
        uint256 callCount
    ) public {
        messageFee = bound(messageFee, 0, 100 ether);
        startNonce = uint32(bound(startNonce, 0, type(uint32).max - 1));
        callCount = bound(callCount, 0, 8);

        MockWormhole wormhole = new MockWormhole();
        wormhole.setMessageFee(messageFee);

        vm.prank(admin);
        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        vm.prank(admin);
        encoder.emergencySetNonce(chainId, startNonce);

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
                (
                    uint32(0),
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(startNonce), chainId, action.calls))
                    ),
                    uint8(1)
                )
            )
        );
        assertEq(encoder.nonces(chainId), uint256(startNonce) + 1);
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

        vm.prank(admin);
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

        assertEq(encoder.nonces(chainId), 0);
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
        vm.prank(admin);
        WormholeEncoder encoder = new WormholeEncoder(address(wormhole), senderHub);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](0);

        vm.prank(caller);
        (bool success, bytes memory returnData) =
            address(encoder).call(abi.encodeCall(WormholeEncoder.encode, (receiverHub, action)));

        if (caller == senderHub) {
            assertTrue(success);
            assertEq(encoder.nonces(chainId), 1);
        } else {
            assertFalse(success);
            assertEq(returnData, abi.encodeWithSelector(IEncoder.NotSenderHub.selector));
            assertEq(encoder.nonces(chainId), 0);
        }
    }
}
