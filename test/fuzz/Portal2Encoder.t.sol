// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IPortal2Calls} from "src/modules/optimism-portal2/IPortal2Calls.sol";
import {Portal2Encoder} from "src/modules/optimism-portal2/Portal2Encoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract Portal2EncoderFuzzTest is Test {
    address internal admin = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);
    address internal fixedPortal = vm.addr(102);

    function testFuzzSetGasLimit(address owner, address caller, bool callerIsOwner, uint64 gasLimit)
        public
    {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        Portal2Encoder encoder = new Portal2Encoder();

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit Portal2Encoder.SetGasLimit(gasLimit);

            vm.prank(caller);
            encoder.setGasLimit(gasLimit);

            assertEq(encoder.gasLimit(), gasLimit);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setGasLimit(gasLimit);

            assertEq(encoder.gasLimit(), 0);
        }
    }

    function testFuzzSetPortal(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        address portal
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        Portal2Encoder encoder = new Portal2Encoder();

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit Portal2Encoder.SetPortal(chainId, portal);

            vm.prank(caller);
            encoder.setPortal(chainId, portal);

            assertEq(encoder.portals(chainId), portal);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setPortal(chainId, portal);

            assertEq(encoder.portals(chainId), address(0x00));
        }
    }

    function testFuzzEncode(
        address receiverHub,
        uint256 chainId,
        address portal,
        uint64 gasLimit,
        uint256[8] calldata callValues
    ) public {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;
        if (portal == address(0x00)) portal = fixedPortal;

        vm.prank(admin);
        Portal2Encoder encoder = new Portal2Encoder();

        vm.prank(admin);
        encoder.setPortal(chainId, portal);

        vm.prank(admin);
        encoder.setGasLimit(gasLimit);

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
        assertEq(bridgeCalls[0].target, portal);
        assertEq(bridgeCalls[0].value, value);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    value,
                    gasLimit,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testFuzzEncodeReceiverHubZero(uint256 chainId, uint256 callCount) public {
        callCount = bound(callCount, 0, 8);

        vm.prank(admin);
        Portal2Encoder encoder = new Portal2Encoder();

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
        Portal2Encoder encoder = new Portal2Encoder();

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        assertEq(encoder.portals(chainId), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }
}
