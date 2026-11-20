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

contract L1CrossDomainMessengerDecoderTest is Test {
    L1CrossDomainMessengerDecoder internal decoder;
    MockMessenger internal messenger;

    address internal bob = vm.addr(1);
    address internal senderHub = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal callTargetA = vm.addr(4);
    address internal callTargetB = vm.addr(5);
    address internal callTargetC = vm.addr(6);
    address internal codelessMessenger = vm.addr(7);

    address internal aliasedSenderHub;

    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes4 internal constant WRONG_SELECTOR = 0x11223344;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant SHORT_PAYLOAD = hex"112233";
    bytes internal constant GARBAGE_TAIL = hex"deadbeef";

    function setUp() public {
        messenger = new MockMessenger();
        messenger.setXDomainMessageSender(senderHub);

        decoder = new L1CrossDomainMessengerDecoder(senderHub, receiverHub, address(messenger));
        aliasedSenderHub = address(uint160(senderHub) + OP_STACK_ALIAS);
    }

    function testConstructor() public {
        L1CrossDomainMessengerDecoder fresh =
            new L1CrossDomainMessengerDecoder(senderHub, receiverHub, address(messenger));

        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.RECEIVER_HUB(), receiverHub);
        assertEq(fresh.L2_MESSENGER(), address(messenger));
    }

    function testDecode() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoded[0].value, FIRST_VALUE);
        assertEq(decoded[0].data, CALL_DATA);
    }

    function testDecodeEmptyCalls() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );

        assertEq(decoded.length, 0);
    }

    function testDecodeMultipleCalls() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );

        assertEq(decoded.length, 3);
        for (uint256 i; i < 3; i++) {
            assertEq(decoded[i].target, calls[i].target);
            assertEq(decoded[i].value, calls[i].value);
            assertEq(decoded[i].data, calls[i].data);
        }
    }

    function testDecodeCallerNotReceiverHub() public {
        Call[] memory calls = new Call[](0);

        vm.prank(bob);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeInvalidReceiverHubCaller() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
        decoder.decode(
            bob, abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeCallerIsSenderHub() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
        decoder.decode(
            senderHub, abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeCallerIsAliasedSenderHub() public {
        Call[] memory calls = new Call[](0);

        // A deposit the Sender Hub makes on the portal directly reaches the Receiver Hub from its
        // alias, which this decoder does not accept.
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
        decoder.decode(
            aliasedSenderHub,
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeNotFromSenderHub() public {
        messenger.setXDomainMessageSender(bob);

        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeFromAliasedSenderHub() public {
        messenger.setXDomainMessageSender(aliasedSenderHub);

        Call[] memory calls = new Call[](0);

        // The messenger reports the L1 sender as is, an aliased Sender Hub is another account.
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeMessengerNotRelaying() public {
        messenger.clearXDomainMessageSender();

        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert("CrossDomainMessenger: xDomainMessageSender is not set");
        decoder.decode(
            address(messenger),
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
        );
    }

    function testDecodeMessengerWithoutCode() public {
        L1CrossDomainMessengerDecoder codeless =
            new L1CrossDomainMessengerDecoder(senderHub, receiverHub, codelessMessenger);

        Call[] memory calls = new Call[](0);

        assertEq(codelessMessenger.code.length, 0);

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(codeless)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        codelessMessenger,
                        abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeCalldataTooShort() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(address(messenger), SHORT_PAYLOAD);
    }

    function testDecodeExactlyFourBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        address(messenger),
                        abi.encodePacked(
                            ICrossDomainMessengerCalls.crossDomainMessengerCall.selector
                        )
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeInvalidSelector() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidSelector.selector);
        decoder.decode(
            address(messenger), abi.encodeWithSelector(WRONG_SELECTOR, abi.encode(calls))
        );
    }

    function testDecodeMalformedPayload() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        address(messenger),
                        abi.encodePacked(
                            ICrossDomainMessengerCalls.crossDomainMessengerCall.selector,
                            GARBAGE_TAIL
                        )
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeCheckOrderCallerBeforeSender() public {
        messenger.setXDomainMessageSender(bob);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
        decoder.decode(bob, SHORT_PAYLOAD);
    }

    function testDecodeCheckOrderSenderBeforeLength() public {
        messenger.setXDomainMessageSender(bob);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(address(messenger), SHORT_PAYLOAD);
    }
}
