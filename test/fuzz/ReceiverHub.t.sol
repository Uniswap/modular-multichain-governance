// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {Call} from "src/types/Call.sol";
import {MockDecoder} from "test/mocks/MockDecoder.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";

contract ReceiverHubFuzzTest is Test {
    address internal admin = vm.addr(100);
    address internal relayer = vm.addr(101);
    bytes4 internal constant DECODER_SELECTOR = 0x11223344;

    function testFuzzSetDecoder(
        address owner,
        address caller,
        bool callerIsOwner,
        bytes4 selector,
        address decoder
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        ReceiverHub receiverHub = new ReceiverHub();

        assertEq(receiverHub.owner(), owner);

        if (caller == owner) {
            vm.expectEmit(address(receiverHub));
            emit IReceiverHub.SetDecoder(selector, decoder);

            vm.prank(caller);
            receiverHub.setDecoder(selector, decoder);

            assertEq(receiverHub.decoders(selector), decoder);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            receiverHub.setDecoder(selector, decoder);

            assertEq(receiverHub.decoders(selector), address(0x00));
        }
    }

    function testFuzzSetSupportsInterface(
        address owner,
        address caller,
        bool callerIsOwner,
        bytes4 interfaceId,
        bool support
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        vm.prank(owner);
        ReceiverHub receiverHub = new ReceiverHub();

        if (caller == owner) {
            vm.expectEmit(address(receiverHub));
            emit IReceiverHub.SetSupportsInterface(interfaceId, support);

            vm.prank(caller);
            receiverHub.setSupportsInterface(interfaceId, support);

            assertEq(receiverHub.supportsInterface(interfaceId), support);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            receiverHub.setSupportsInterface(interfaceId, support);

            assertFalse(receiverHub.supportsInterface(interfaceId));
        }
    }

    function testFuzzFallback(
        bytes4 selector,
        bytes calldata suffix,
        address caller,
        uint256 callCount
    ) public {
        vm.assume(
            selector != IReceiverHub.decoders.selector
                && selector != IReceiverHub.supportsInterface.selector
                && selector != IReceiverHub.setDecoder.selector
                && selector != IReceiverHub.setSupportsInterface.selector
                && selector != bytes4(keccak256("owner()"))
                && selector != bytes4(keccak256("transferOwnership(address)"))
        );
        vm.assume(caller != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);

        vm.prank(admin);
        ReceiverHub receiverHub = new ReceiverHub();

        MockDecoder decoder = new MockDecoder();
        MockTarget target = new MockTarget();

        vm.prank(admin);
        receiverHub.setDecoder(selector, address(decoder));

        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = Call({target: address(target), value: 0, data: abi.encode(i)});
        }
        decoder.setReturnCalls(calls);

        bytes memory payload = abi.encodePacked(selector, suffix);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(caller, selector, address(decoder));

        vm.prank(caller);
        (bool success,) = address(receiverHub).call(payload);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 1);
        assertEq(decoder.lastCaller(), caller);
        assertEq(decoder.lastData(), payload);
        assertEq(target.callCount(), callCount);

        for (uint256 i; i < callCount; i++) {
            assertEq(target.dataAt(i), abi.encode(i));
        }
    }

    function testFuzzFallbackDecoderNotSet(bytes4 selector, bytes calldata suffix, address caller)
        public
    {
        vm.assume(
            selector != IReceiverHub.decoders.selector
                && selector != IReceiverHub.supportsInterface.selector
                && selector != IReceiverHub.setDecoder.selector
                && selector != IReceiverHub.setSupportsInterface.selector
                && selector != bytes4(keccak256("owner()"))
                && selector != bytes4(keccak256("transferOwnership(address)"))
        );
        vm.assume(caller != VM_ADDRESS);

        vm.prank(admin);
        ReceiverHub receiverHub = new ReceiverHub();

        assertEq(receiverHub.decoders(selector), address(0x00));

        vm.prank(caller);
        (bool success, bytes memory returnData) =
            address(receiverHub).call(abi.encodePacked(selector, suffix));

        assertFalse(success);
        assertEq(
            returnData, abi.encodeWithSelector(IReceiverHub.NoDecoderForSelector.selector, selector)
        );
    }

    function testFuzzFallbackCallFail(address target, uint256 value, bytes calldata data) public {
        vm.assume(target != VM_ADDRESS);

        value = bound(value, 1, type(uint256).max);

        vm.prank(admin);
        ReceiverHub receiverHub = new ReceiverHub();

        MockDecoder decoder = new MockDecoder();

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: value, data: data});
        decoder.setReturnCalls(calls);

        assertEq(address(receiverHub).balance, 0);

        vm.prank(relayer);
        (bool success, bytes memory returnData) =
            address(receiverHub).call(abi.encodePacked(DECODER_SELECTOR));

        assertFalse(success);
        assertEq(
            returnData, abi.encodeWithSelector(IReceiverHub.CallFail.selector, target, bytes(""))
        );
    }

    function testFuzzReceive(address sender, uint256 value) public {
        vm.assume(sender != VM_ADDRESS);

        value = bound(value, 0, 100 ether);

        vm.prank(admin);
        ReceiverHub receiverHub = new ReceiverHub();

        vm.assume(sender != address(receiverHub));

        vm.deal(sender, value);
        vm.deal(address(this), value);

        vm.recordLogs();

        vm.prank(sender);
        (bool success, bytes memory returnData) = address(receiverHub).call{value: value}("");

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(address(receiverHub).balance, value);
        assertEq(vm.getRecordedLogs().length, 0);
    }
}
