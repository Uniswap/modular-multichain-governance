// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {
    L1CrossDomainMessengerDecoder
} from "src/modules/optimism-messenger/L1CrossDomainMessengerDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MockMessenger} from "test/mocks/MockMessenger.sol";

contract L1CrossDomainMessengerDecoderFuzzTest is Test {
    /// @dev Sender the messenger holds while it is not relaying, which the mock treats as unset.
    address internal constant UNSET_SENDER = 0x000000000000000000000000000000000000dEaD;

    MockMessenger internal messenger;

    address internal senderHub = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    function setUp() public {
        messenger = new MockMessenger();
    }

    function testFuzzDecode(
        address caller,
        address receiverHub,
        address messageSender,
        bool callerIsMessenger,
        bool fromSenderHub,
        uint256 callCount
    ) public {
        vm.assume(receiverHub != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);

        if (callerIsMessenger) caller = address(messenger);
        else if (caller == address(messenger)) caller = address(uint160(caller) ^ 1);

        if (fromSenderHub) messageSender = senderHub;
        else if (messageSender == senderHub) messageSender = address(uint160(messageSender) ^ 1);

        vm.assume(messageSender != UNSET_SENDER);

        messenger.setXDomainMessageSender(messageSender);

        L1CrossDomainMessengerDecoder decoder =
            new L1CrossDomainMessengerDecoder(senderHub, receiverHub, address(messenger));

        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bytes memory payload =
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls));

        address notReceiverHub = address(uint160(receiverHub) ^ 1);
        vm.assume(notReceiverHub != VM_ADDRESS);

        vm.prank(notReceiverHub);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(caller, payload);

        if (caller != address(messenger)) {
            vm.prank(receiverHub);
            vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
            decoder.decode(caller, payload);
        } else if (messageSender != senderHub) {
            vm.prank(receiverHub);
            vm.expectRevert(IDecoder.NotFromSenderHub.selector);
            decoder.decode(caller, payload);
        } else {
            vm.prank(receiverHub);
            Call[] memory decoded = decoder.decode(caller, payload);

            assertEq(decoded.length, callCount);
            for (uint256 i; i < callCount; i++) {
                assertEq(decoded[i].target, calls[i].target);
                assertEq(decoded[i].value, calls[i].value);
                assertEq(decoded[i].data, calls[i].data);
            }
        }
    }

    function testFuzzDecodeShortCalldata(bytes calldata data) public {
        uint256 length = bound(data.length, 0, 3);

        bytes memory short = new bytes(length);
        for (uint256 i; i < length; i++) {
            short[i] = data[i];
        }

        messenger.setXDomainMessageSender(senderHub);

        address receiverHub = fixedReceiverHub;
        L1CrossDomainMessengerDecoder decoder =
            new L1CrossDomainMessengerDecoder(senderHub, receiverHub, address(messenger));

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(address(messenger), short);
    }

    function testFuzzDecodeInvalidSelector(bytes4 selector, bytes calldata tail) public {
        vm.assume(selector != ICrossDomainMessengerCalls.crossDomainMessengerCall.selector);

        messenger.setXDomainMessageSender(senderHub);

        address receiverHub = fixedReceiverHub;
        L1CrossDomainMessengerDecoder decoder =
            new L1CrossDomainMessengerDecoder(senderHub, receiverHub, address(messenger));

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidSelector.selector);
        decoder.decode(address(messenger), abi.encodePacked(selector, tail));
    }
}
