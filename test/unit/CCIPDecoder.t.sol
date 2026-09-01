// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {CCIPDecoder} from "src/modules/ccip/CCIPDecoder.sol";
import {CCIPError} from "src/modules/ccip/CCIPError.sol";
import {
    Any2EVMMessage,
    IAny2EVMMessageReceiver
} from "src/modules/ccip/IAny2EVMMessageReceiver.sol";
import {EVMTokenAmount} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";

contract CCIPDecoderTest is Test {
    CCIPDecoder internal decoder;

    address internal bob = vm.addr(1);
    address internal senderHub = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal router = vm.addr(4);
    address internal callTargetA = vm.addr(5);
    address internal callTargetB = vm.addr(6);
    address internal callTargetC = vm.addr(7);
    address internal tokenA = vm.addr(8);
    address internal tokenB = vm.addr(9);

    uint64 internal constant L1_CHAIN_SELECTOR = 5009297550715157269;
    uint64 internal constant WRONG_CHAIN_SELECTOR = 1234;

    bytes32 internal constant MESSAGE_ID = bytes32(uint256(7));

    uint256 internal constant DIRTY_BIT_POSITION = 200;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;
    uint256 internal constant TOKEN_AMOUNT = 1 ether;

    bytes4 internal constant WRONG_SELECTOR = 0x11223344;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant SHORT_PAYLOAD = hex"112233";
    bytes internal constant GARBAGE_TAIL = hex"deadbeef";
    bytes internal constant TRUNCATED_SENDER = hex"1122";

    function setUp() public {
        decoder = new CCIPDecoder(senderHub, receiverHub, router);
    }

    function testConstructor() public {
        CCIPDecoder fresh = new CCIPDecoder(senderHub, receiverHub, router);

        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.RECEIVER_HUB(), receiverHub);
        assertEq(fresh.ROUTER(), router);
    }

    function testDecode() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(calls),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoded[0].value, FIRST_VALUE);
        assertEq(decoded[0].data, CALL_DATA);
    }

    function testDecodeEmptyCalls() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));

        assertEq(decoded.length, 0);
    }

    function testDecodeMultipleCalls() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(calls),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));

        assertEq(decoded.length, 3);
        for (uint256 i; i < 3; i++) {
            assertEq(decoded[i].target, calls[i].target);
            assertEq(decoded[i].value, calls[i].value);
            assertEq(decoded[i].data, calls[i].data);
        }
    }

    function testDecodeCallerNotReceiverHub() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(bob);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeReceiverHubCallerNotRouter() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(CCIPError.ReceiverHubCallerNotRouter.selector);
        decoder.decode(bob, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeCalldataTooShort() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(router, SHORT_PAYLOAD);
    }

    function testDecodeExactlyFourBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (router, abi.encodePacked(IAny2EVMMessageReceiver.ccipReceive.selector))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeInvalidSelector() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidSelector.selector);
        decoder.decode(router, abi.encodeWithSelector(WRONG_SELECTOR, message));
    }

    function testDecodeInvalidSourceChain() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: WRONG_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(CCIPError.InvalidSourceChain.selector);
        decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeInvalidSourceChainZero() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: 0,
            sender: abi.encode(senderHub),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(CCIPError.InvalidSourceChain.selector);
        decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeNotFromSenderHub() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(bob),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeSenderDirtyBits() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encodePacked(
                bytes32(uint256(uint160(senderHub)) | (uint256(1) << DIRTY_BIT_POSITION))
            ),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeSenderWrongLength() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: TRUNCATED_SENDER,
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeMalformedMessage() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        router,
                        abi.encodePacked(IAny2EVMMessageReceiver.ccipReceive.selector, GARBAGE_TAIL)
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeMalformedMessageData() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: GARBAGE_TAIL,
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeCheckOrder() public {
        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: WRONG_CHAIN_SELECTOR,
            sender: abi.encode(bob),
            data: abi.encode(new Call[](0)),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        vm.expectRevert(CCIPError.InvalidSourceChain.selector);
        decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
    }

    function testDecodeMessageIdIgnored() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        Any2EVMMessage memory zeroId = Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(calls),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        Any2EVMMessage memory maxId = Any2EVMMessage({
            messageId: bytes32(type(uint256).max),
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(calls),
            destTokenAmounts: new EVMTokenAmount[](0)
        });

        vm.prank(receiverHub);
        Call[] memory decodedZero =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (zeroId)));

        vm.prank(receiverHub);
        Call[] memory decodedMax =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (maxId)));

        assertEq(decodedZero.length, 1);
        assertEq(decodedMax.length, 1);
        assertEq(decodedZero[0].target, decodedMax[0].target);
        assertEq(decodedZero[0].data, decodedMax[0].data);
    }

    function testDecodeDestTokenAmountsIgnored() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        EVMTokenAmount[] memory tokenAmounts = new EVMTokenAmount[](2);
        tokenAmounts[0] = EVMTokenAmount({token: tokenA, amount: TOKEN_AMOUNT});
        tokenAmounts[1] = EVMTokenAmount({token: tokenB, amount: 2 * TOKEN_AMOUNT});

        Any2EVMMessage memory message = Any2EVMMessage({
            messageId: MESSAGE_ID,
            sourceChainSelector: L1_CHAIN_SELECTOR,
            sender: abi.encode(senderHub),
            data: abi.encode(calls),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(receiverHub);
        Call[] memory decoded =
            decoder.decode(router, abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoded[0].data, CALL_DATA);
    }
}
