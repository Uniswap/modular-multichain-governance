// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IFxMessageProcessor} from "src/interfaces/bridges/IFxMessageProcessor.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {FxDecoder} from "src/modules/fx/FxDecoder.sol";
import {Call} from "src/types/Call.sol";

contract FxDecoderTest is Test {
    FxDecoder internal decoder;

    address internal bob = vm.addr(1);
    address internal senderHub = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal fxChild = vm.addr(4);
    address internal callTargetA = vm.addr(5);
    address internal callTargetB = vm.addr(6);
    address internal callTargetC = vm.addr(7);

    uint256 internal constant STATE_ID = 7;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes4 internal constant WRONG_SELECTOR = 0x11223344;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant SHORT_PAYLOAD = hex"112233";
    bytes internal constant GARBAGE_TAIL = hex"deadbeef";

    function setUp() public {
        decoder = new FxDecoder(senderHub, receiverHub, fxChild);
    }

    function testConstructor() public {
        FxDecoder fresh = new FxDecoder(senderHub, receiverHub, fxChild);

        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.RECEIVER_HUB(), receiverHub);
        assertEq(fresh.FX_CHILD(), fxChild);
    }

    function testDecode() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, senderHub, abi.encode(calls))
            )
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
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, senderHub, abi.encode(calls))
            )
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
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, senderHub, abi.encode(calls))
            )
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
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, senderHub, abi.encode(calls))
            )
        );
    }

    function testDecodeInvalidReceiverHubCaller() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
        decoder.decode(
            bob,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, senderHub, abi.encode(calls))
            )
        );
    }

    function testDecodeNotFromSenderHub() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (STATE_ID, bob, abi.encode(calls))
            )
        );
    }

    function testDecodeCalldataTooShort() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(fxChild, SHORT_PAYLOAD);
    }

    function testDecodeExactlyFourBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (fxChild, abi.encodePacked(IFxMessageProcessor.processMessageFromRoot.selector))
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
            fxChild, abi.encodeWithSelector(WRONG_SELECTOR, STATE_ID, senderHub, abi.encode(calls))
        );
    }

    function testDecodeStateIdIgnored() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(receiverHub);
        Call[] memory zeroStateId = decoder.decode(
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot, (0, senderHub, abi.encode(calls))
            )
        );

        vm.prank(receiverHub);
        Call[] memory maxStateId = decoder.decode(
            fxChild,
            abi.encodeCall(
                IFxMessageProcessor.processMessageFromRoot,
                (type(uint256).max, senderHub, abi.encode(calls))
            )
        );

        assertEq(zeroStateId.length, 1);
        assertEq(maxStateId.length, 1);
        assertEq(zeroStateId[0].target, maxStateId[0].target);
        assertEq(zeroStateId[0].data, maxStateId[0].data);
    }

    function testDecodeMalformedOuterPayload() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        fxChild,
                        abi.encodePacked(
                            IFxMessageProcessor.processMessageFromRoot.selector, GARBAGE_TAIL
                        )
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeMalformedInnerCalls() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        fxChild,
                        abi.encodeCall(
                            IFxMessageProcessor.processMessageFromRoot,
                            (STATE_ID, senderHub, GARBAGE_TAIL)
                        )
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}
