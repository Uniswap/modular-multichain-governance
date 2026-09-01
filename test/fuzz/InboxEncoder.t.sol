// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IInbox} from "src/interfaces/bridges/IInbox.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IArbitrumCalls} from "src/modules/arbitrum-orbit/IArbitrumCalls.sol";
import {InboxEncoder} from "src/modules/arbitrum-orbit/InboxEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract InboxEncoderFuzzTest is Test {
    address internal admin = vm.addr(101);
    address internal fixedReceiverHub = vm.addr(102);
    address internal fixedInbox = vm.addr(103);
    address internal timelock = vm.addr(100);

    function testFuzzSetGasParameters(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        uint256 maxSubmissionCost
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        InboxEncoder encoder = new InboxEncoder(timelock);

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit InboxEncoder.SetGasParameters(gasLimit, maxFeePerGas, maxSubmissionCost);

            vm.prank(caller);
            encoder.setGasParameters(gasLimit, maxFeePerGas, maxSubmissionCost);

            assertEq(encoder.gasLimit(), gasLimit);
            assertEq(encoder.maxFeePerGas(), maxFeePerGas);
            assertEq(encoder.maxSubmissionCost(), maxSubmissionCost);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setGasParameters(gasLimit, maxFeePerGas, maxSubmissionCost);

            assertEq(encoder.gasLimit(), 0);
            assertEq(encoder.maxFeePerGas(), 0);
            assertEq(encoder.maxSubmissionCost(), 0);
        }
    }

    function testFuzzSetInbox(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        address inbox
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        InboxEncoder encoder = new InboxEncoder(timelock);

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit InboxEncoder.SetInbox(chainId, inbox);

            vm.prank(caller);
            encoder.setInbox(chainId, inbox);

            assertEq(encoder.inboxes(chainId), inbox);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setInbox(chainId, inbox);

            assertEq(encoder.inboxes(chainId), address(0x00));
        }
    }

    function testFuzzEncode(
        address receiverHub,
        uint256 chainId,
        address inbox,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        uint256 maxSubmissionCost,
        uint256[8] calldata callValues
    ) public {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;
        if (inbox == address(0x00)) inbox = fixedInbox;

        gasLimit = bound(gasLimit, 0, 1_000_000_000);
        maxFeePerGas = bound(maxFeePerGas, 0, 1_000 gwei);
        maxSubmissionCost = bound(maxSubmissionCost, 0, 1 ether);

        vm.prank(admin);
        InboxEncoder encoder = new InboxEncoder(timelock);

        vm.prank(admin);
        encoder.setInbox(chainId, inbox);

        vm.prank(admin);
        encoder.setGasParameters(gasLimit, maxFeePerGas, maxSubmissionCost);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](8);

        uint256 l2CallValue;
        for (uint256 i; i < 8; i++) {
            uint256 callValue = bound(callValues[i], 0, 10 ether);
            l2CallValue += callValue;
            action.calls[i] = Call({target: vm.addr(i + 1), value: callValue, data: abi.encode(i)});
        }

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        uint256 gasValue = (gasLimit * maxFeePerGas) + maxSubmissionCost;

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, inbox);
        assertEq(bridgeCalls[0].value, l2CallValue + gasValue);
        assertEq(bridgeCalls[0].value - l2CallValue, gasValue);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    l2CallValue,
                    maxSubmissionCost,
                    timelock,
                    timelock,
                    gasLimit,
                    maxFeePerGas,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
    }

    function testFuzzEncodeReceiverHubZero(uint256 chainId, uint256 callCount) public {
        callCount = bound(callCount, 0, 8);

        vm.prank(admin);
        InboxEncoder encoder = new InboxEncoder(timelock);

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
        InboxEncoder encoder = new InboxEncoder(timelock);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        assertEq(encoder.inboxes(chainId), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }
}
