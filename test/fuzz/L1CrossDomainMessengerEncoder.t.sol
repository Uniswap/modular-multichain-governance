// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {
    L1CrossDomainMessengerEncoder
} from "src/modules/optimism-messenger/L1CrossDomainMessengerEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract L1CrossDomainMessengerEncoderFuzzTest is Test {
    address internal admin = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);
    address internal fixedMessenger = vm.addr(102);

    function testFuzzSetMinGasLimit(
        address owner,
        address caller,
        bool callerIsOwner,
        uint32 minGasLimit
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        L1CrossDomainMessengerEncoder encoder = new L1CrossDomainMessengerEncoder();

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit L1CrossDomainMessengerEncoder.SetMinGasLimit(minGasLimit);

            vm.prank(caller);
            encoder.setMinGasLimit(minGasLimit);

            assertEq(encoder.minGasLimit(), minGasLimit);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setMinGasLimit(minGasLimit);

            assertEq(encoder.minGasLimit(), 0);
        }
    }

    function testFuzzSetMessenger(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        address messenger
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        L1CrossDomainMessengerEncoder encoder = new L1CrossDomainMessengerEncoder();

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit L1CrossDomainMessengerEncoder.SetMessenger(chainId, messenger);

            vm.prank(caller);
            encoder.setMessenger(chainId, messenger);

            assertEq(encoder.messengers(chainId), messenger);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setMessenger(chainId, messenger);

            assertEq(encoder.messengers(chainId), address(0x00));
        }
    }

    function testFuzzEncode(
        address receiverHub,
        uint256 chainId,
        address messenger,
        uint32 minGasLimit,
        uint256[8] calldata callValues
    ) public {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;
        if (messenger == address(0x00)) messenger = fixedMessenger;

        vm.prank(admin);
        L1CrossDomainMessengerEncoder encoder = new L1CrossDomainMessengerEncoder();

        vm.prank(admin);
        encoder.setMessenger(chainId, messenger);

        vm.prank(admin);
        encoder.setMinGasLimit(minGasLimit);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](8);

        uint256 value;
        for (uint256 i; i < 8; i++) {
            uint256 callValue = bound(callValues[i], 0, 10 ether);
            value += callValue;
            action.calls[i] = Call({target: vm.addr(i + 1), value: callValue, data: abi.encode(i)});
        }

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, messenger);
        assertEq(bridgeCalls[0].value, value);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall, (action.calls)
                    ),
                    minGasLimit
                )
            )
        );
    }

    function testFuzzEncodeReceiverHubZero(uint256 chainId, uint256 callCount) public {
        callCount = bound(callCount, 0, 8);

        vm.prank(admin);
        L1CrossDomainMessengerEncoder encoder = new L1CrossDomainMessengerEncoder();

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testFuzzEncodeBridgeNotSet(address receiverHub, uint256 chainId, uint256 callCount)
        public
    {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;

        callCount = bound(callCount, 0, 8);

        vm.prank(admin);
        L1CrossDomainMessengerEncoder encoder = new L1CrossDomainMessengerEncoder();

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        assertEq(encoder.messengers(chainId), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }
}
