// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {WormholeEncoder} from "src/modules/wormhole/WormholeEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockWormhole} from "test/mocks/MockWormhole.sol";

contract WormholeEncoderTest is Test {
    WormholeEncoder internal encoder;
    MockWormhole internal wormhole;

    address internal bob = vm.addr(2);
    address internal senderHub = vm.addr(3);
    address internal receiverHub = vm.addr(4);
    address internal otherReceiverHub = vm.addr(5);
    address internal wormholeEoa = vm.addr(6);
    address internal callTargetA = vm.addr(7);
    address internal callTargetB = vm.addr(8);
    address internal callTargetC = vm.addr(9);

    uint256 internal constant CHAIN_ID = 8453;
    uint256 internal constant OTHER_CHAIN_ID = 42161;
    uint256 internal constant LARGE_CHAIN_ID = 81457;

    uint32 internal constant WORMHOLE_NONCE_FIELD = 0;
    uint8 internal constant CONSISTENCY_LEVEL = 1;

    uint256 internal constant FIRST_MESSAGE_ID = 1;
    uint256 internal constant SECOND_MESSAGE_ID = 2;
    uint256 internal constant THIRD_MESSAGE_ID = 3;

    uint256 internal constant MESSAGE_FEE = 0.01 ether;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        wormhole = new MockWormhole();
        encoder = new WormholeEncoder(address(wormhole), senderHub);
    }

    function testConstructor() public {
        WormholeEncoder fresh = new WormholeEncoder(address(wormhole), senderHub);

        assertEq(fresh.WORMHOLE(), address(wormhole));
        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.CONSISTENCY_LEVEL(), CONSISTENCY_LEVEL);
        assertEq(fresh.messageId(), 0);

        (bool success, bytes memory returnData) =
            address(fresh).call(abi.encodeWithSignature("owner()"));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testEncode() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, address(wormhole));
        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(FIRST_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeCallerNotSenderHub() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        vm.expectRevert(IEncoder.NotSenderHub.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.messageId(), 0);
    }

    function testEncodeWormholeNonceFieldZero() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(SECOND_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeMessageIdInPayload() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        Call[] memory firstBridgeCalls = encoder.encode(receiverHub, action);

        vm.prank(senderHub);
        Call[] memory secondBridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            firstBridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(FIRST_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(
            secondBridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(SECOND_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(encoder.messageId(), SECOND_MESSAGE_ID);
    }

    function testEncodeIncrementsMessageId() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.messageId(), 0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        assertEq(encoder.messageId(), FIRST_MESSAGE_ID);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        assertEq(encoder.messageId(), SECOND_MESSAGE_ID);
    }

    function testEncodeMessageIdSharedAcrossChains() public {
        MultichainAction memory actionA;
        actionA.chainId = CHAIN_ID;
        actionA.calls = new Call[](0);

        MultichainAction memory actionB;
        actionB.chainId = OTHER_CHAIN_ID;
        actionB.calls = new Call[](0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, actionA);

        vm.prank(senderHub);
        encoder.encode(receiverHub, actionA);

        assertEq(encoder.messageId(), SECOND_MESSAGE_ID);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, actionB);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(THIRD_MESSAGE_ID, OTHER_CHAIN_ID, actionB.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(encoder.messageId(), THIRD_MESSAGE_ID);
    }

    function testEncodeEmptyCalls() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
    }

    function testEncodeMultipleCalls() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(FIRST_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeLargeChainId() public {
        MultichainAction memory action;
        action.chainId = LARGE_CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertTrue(action.chainId > type(uint16).max);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(FIRST_MESSAGE_ID, LARGE_CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeZeroMessageFee() public {
        wormhole.setMessageFee(0);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
    }

    function testEncodeReceiverHubIgnored() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory withZero = encoder.encode(address(0x00), action);

        vm.prank(senderHub);
        Call[] memory withAddress = encoder.encode(otherReceiverHub, action);

        assertEq(withZero[0].target, withAddress[0].target);
        assertEq(withZero[0].value, withAddress[0].value);
        assertEq(
            withZero[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(FIRST_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(
            withAddress[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encode(SECOND_MESSAGE_ID, CHAIN_ID, action.calls),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeInvalidCallValue() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueLastCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueMiddleCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueDoesNotIncrementMessageId() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.messageId(), 0);
    }

    function testEncodeAllZeroCallValues() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(encoder.messageId(), FIRST_MESSAGE_ID);
    }

    function testEncodeCheckOrderCallerBeforeCallValue() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(bob);
        vm.expectRevert(IEncoder.NotSenderHub.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeWormholeNotAContract() public {
        WormholeEncoder eoaWormholeEncoder = new WormholeEncoder(wormholeEoa, senderHub);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(wormholeEoa.code.length, 0);

        vm.prank(senderHub);
        (bool success, bytes memory returnData) = address(eoaWormholeEncoder)
            .call(abi.encodeCall(WormholeEncoder.encode, (receiverHub, action)));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}
