// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IArbitrumCalls} from "src/modules/arbitrum-orbit/IArbitrumCalls.sol";
import {InboxDecoder} from "src/modules/arbitrum-orbit/InboxDecoder.sol";
import {Call} from "src/types/Call.sol";

contract InboxDecoderTest is Test {
    InboxDecoder internal decoder;

    address internal bob = vm.addr(1);
    address internal senderHub = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal callTargetA = vm.addr(4);
    address internal callTargetB = vm.addr(5);
    address internal callTargetC = vm.addr(6);
    address internal sampleL1Address = vm.addr(7);

    address internal aliasedSenderHub;

    address internal constant BELOW_ALIAS_ADDRESS = address(uint160(1));
    uint160 internal constant ARBITRUM_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes4 internal constant WRONG_SELECTOR = 0x11223344;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant SHORT_PAYLOAD = hex"112233";
    bytes internal constant GARBAGE_TAIL = hex"deadbeef";

    function setUp() public {
        decoder = new InboxDecoder(senderHub, receiverHub);
        aliasedSenderHub = address(uint160(senderHub) + ARBITRUM_ALIAS);
    }

    function testConstructor() public {
        InboxDecoder fresh = new InboxDecoder(senderHub, receiverHub);

        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.RECEIVER_HUB(), receiverHub);
    }

    function testDecode() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(aliasedSenderHub, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoded[0].value, FIRST_VALUE);
        assertEq(decoded[0].data, CALL_DATA);
    }

    function testDecodeEmptyCalls() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(aliasedSenderHub, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));

        assertEq(decoded.length, 0);
    }

    function testDecodeMultipleCalls() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(aliasedSenderHub, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));

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
        decoder.decode(aliasedSenderHub, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));
    }

    function testDecodeNotFromSenderHub() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(bob, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));
    }

    function testDecodeUnaliasedSenderHub() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(senderHub, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));
    }

    function testDecodeCalldataTooShort() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(aliasedSenderHub, SHORT_PAYLOAD);
    }

    function testDecodeExactlyFourBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (aliasedSenderHub, abi.encodePacked(IArbitrumCalls.arbitrumCall.selector))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeInvalidSelector() public {
        Call[] memory calls = new Call[](0);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidSelector.selector);
        decoder.decode(aliasedSenderHub, abi.encodeWithSelector(WRONG_SELECTOR, abi.encode(calls)));
    }

    function testDecodeMalformedPayload() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        aliasedSenderHub,
                        abi.encodePacked(IArbitrumCalls.arbitrumCall.selector, GARBAGE_TAIL)
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeAliasWrap() public {
        address wrappingSenderHub = address(type(uint160).max);
        InboxDecoder wrapping = new InboxDecoder(wrappingSenderHub, receiverHub);

        address wrappedCaller;
        unchecked {
            wrappedCaller = address(uint160(wrappingSenderHub) + ARBITRUM_ALIAS);
        }

        assertEq(wrappedCaller, address(ARBITRUM_ALIAS - 1));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(receiverHub);
        Call[] memory decoded =
            wrapping.decode(wrappedCaller, abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls)));

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
    }

    function testDecodeCheckOrder() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(bob, SHORT_PAYLOAD);
    }

    function testRemoveAlias() public view {
        assertEq(
            decoder.removeAlias(address(uint160(sampleL1Address) + ARBITRUM_ALIAS)), sampleL1Address
        );
        assertEq(decoder.removeAlias(aliasedSenderHub), senderHub);
        assertEq(decoder.removeAlias(address(ARBITRUM_ALIAS)), address(0x00));
    }

    function testRemoveAliasZero() public view {
        address expected;
        unchecked {
            expected = address(uint160(0) - ARBITRUM_ALIAS);
        }

        assertEq(decoder.removeAlias(address(0x00)), expected);
    }

    function testRemoveAliasUnderflow() public view {
        address expected;
        unchecked {
            expected = address(uint160(BELOW_ALIAS_ADDRESS) - ARBITRUM_ALIAS);
        }

        assertEq(decoder.removeAlias(BELOW_ALIAS_ADDRESS), expected);
        assertEq(decoder.removeAlias(address(ARBITRUM_ALIAS - 1)), address(type(uint160).max));
    }
}
