// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {Signature, VerifiableMessage} from "src/interfaces/bridges/IWormhole.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeDecoder} from "src/modules/wormhole/WormholeDecoder.sol";
import {WormholeError} from "src/modules/wormhole/WormholeError.sol";
import {Call} from "src/types/Call.sol";
import {MockWormhole} from "test/mocks/MockWormhole.sol";

contract WormholeDecoderTest is Test {
    WormholeDecoder internal decoder;
    MockWormhole internal wormhole;

    address internal bob = vm.addr(1);
    address internal senderHub = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal otherReceiverHub = vm.addr(4);
    address internal callTargetA = vm.addr(5);
    address internal callTargetB = vm.addr(6);
    address internal callTargetC = vm.addr(7);

    uint256 internal constant MSG_TIMEOUT = 2 days;
    uint32 internal constant MESSAGE_TIMESTAMP = 1000;

    uint8 internal constant VERSION = 1;
    uint8 internal constant UNCHECKED_VERSION = 123;
    uint8 internal constant CONSISTENCY_LEVEL = 1;
    uint8 internal constant UNFINALIZED_CONSISTENCY_LEVEL = 0;

    uint16 internal constant ETH_WORMHOLE_CHAIN_ID = 2;
    uint16 internal constant WRONG_WORMHOLE_CHAIN_ID = 30;

    uint256 internal constant LARGE_CHAIN_ID = 81457;
    uint256 internal constant WRONG_NONCE = 7;
    uint256 internal constant NEXT_NONCE = 1;
    uint256 internal constant DIRTY_BIT_POSITION = 200;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    string internal constant INVALID_REASON = "bad sig";

    bytes4 internal constant WRONG_SELECTOR = 0x11223344;

    bytes internal constant ENCODED_VM = hex"deadbeef";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant SHORT_PAYLOAD = hex"112233";
    bytes internal constant GARBAGE_PAYLOAD = hex"deadbeef";

    function setUp() public {
        wormhole = new MockWormhole();
        decoder = new WormholeDecoder(senderHub, receiverHub, address(wormhole));
    }

    function testConstructor() public {
        WormholeDecoder fresh = new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.RECEIVER_HUB(), receiverHub);
        assertEq(fresh.WORMHOLE(), address(wormhole));
        assertEq(fresh.nonce(), 0);
    }

    function testDecode() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, calls),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoded[0].value, FIRST_VALUE);
        assertEq(decoded[0].data, CALL_DATA);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeEmptyCalls() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeMultipleCalls() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, calls),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 3);
        for (uint256 i; i < 3; i++) {
            assertEq(decoded[i].target, calls[i].target);
            assertEq(decoded[i].value, calls[i].value);
            assertEq(decoded[i].data, calls[i].data);
        }
    }

    function testDecodeCallerNotReceiverHub() public {
        vm.prank(bob);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeCallerArgumentIgnored() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(NEXT_NONCE, block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        decoder.decode(otherReceiverHub, abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 2);
    }

    function testDecodeCalldataTooShort() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(address(0x00), SHORT_PAYLOAD);
    }

    function testDecodeExactlyFourBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (address(0x00), abi.encodePacked(IWormholeCalls.wormholeCall.selector))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
        assertEq(decoder.nonce(), 0);
    }

    function testDecodeInvalidSelector() public {
        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.InvalidSelector.selector);
        decoder.decode(address(0x00), abi.encodeWithSelector(WRONG_SELECTOR, ENCODED_VM));
    }

    function testDecodeMalformedOuterBytes() public {
        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (
                        address(0x00),
                        abi.encodePacked(IWormholeCalls.wormholeCall.selector, GARBAGE_PAYLOAD)
                    )
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testDecodeInvalidVm() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            false,
            INVALID_REASON
        );

        vm.prank(receiverHub);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, INVALID_REASON)
        );
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeNotFromSenderHub() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(bob))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.NotFromSenderHub.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeEmitterAddressDirtyBits() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(
                    uint256(uint160(senderHub)) | (uint256(1) << DIRTY_BIT_POSITION)
                ),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeNotFromEthereum() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: WRONG_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.NotFromEthereum.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeExpired() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: MESSAGE_TIMESTAMP,
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.warp(MESSAGE_TIMESTAMP + MSG_TIMEOUT + 1);

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.Expired.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeExpiryBoundary() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: MESSAGE_TIMESTAMP,
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.warp(MESSAGE_TIMESTAMP + MSG_TIMEOUT);

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeFutureTimestamp() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: type(uint32).max,
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeSequenceIgnored() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 1);

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: type(uint64).max,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(NEXT_NONCE, block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 2);
    }

    function testDecodeInvalidNonce() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(WRONG_NONCE, block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.InvalidNonce.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeNonceReplay() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.InvalidNonce.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 1);
    }

    function testDecodeNonceOutOfOrder() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(NEXT_NONCE, block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        assertEq(decoder.nonce(), 0);

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.InvalidNonce.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeNonceSequential() public {
        for (uint256 i; i < 3; i++) {
            wormhole.setParseAndVerifyVM(
                VerifiableMessage({
                    version: VERSION,
                    timestamp: uint32(block.timestamp),
                    nonce: 0,
                    emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                    emitterAddress: bytes32(uint256(uint160(senderHub))),
                    sequence: 0,
                    consistencyLevel: CONSISTENCY_LEVEL,
                    payload: abi.encode(i, block.chainid, new Call[](0)),
                    guardianSetIndex: 0,
                    signatures: new Signature[](0),
                    hash: bytes32(0)
                }),
                true,
                ""
            );

            vm.prank(receiverHub);
            decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
        }

        assertEq(decoder.nonce(), 3);
    }

    function testDecodeNonceNotIncrementedOnRevert() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            false,
            INVALID_REASON
        );

        vm.prank(receiverHub);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, INVALID_REASON)
        );
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 0);
    }

    function testDecodeNotToThisChain() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid + 1, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.NotToThisChain.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeLargeChainId() public {
        vm.chainId(LARGE_CHAIN_ID);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), LARGE_CHAIN_ID, calls),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        assertTrue(block.chainid > type(uint16).max);

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 1);
        assertEq(decoded[0].target, callTargetA);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeMalformedPayload() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: GARBAGE_PAYLOAD,
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
        assertEq(decoder.nonce(), 0);
    }

    function testDecodeLegacyTwoElementPayload() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        // The legacy `(uint256, Call[])` shape still decodes as `(uint256, uint256, Call[])`: the
        // array's head offset is read as the chain Id and its length word as the array offset.
        vm.prank(receiverHub);
        vm.expectRevert(WormholeError.NotToThisChain.selector);
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

        assertEq(decoder.nonce(), 0);
    }

    function testDecodeCheckOrderPayloadBeforeNonce() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(WRONG_NONCE, block.chainid),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)))
                )
            );

        assertFalse(success);
        assertEq(returnData.length, 0);
        assertTrue(
            keccak256(returnData)
                != keccak256(abi.encodeWithSelector(WormholeError.InvalidNonce.selector))
        );
        assertEq(decoder.nonce(), 0);
    }

    function testDecodeCheckOrder() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: MESSAGE_TIMESTAMP,
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            false,
            INVALID_REASON
        );

        vm.warp(MESSAGE_TIMESTAMP + MSG_TIMEOUT + 1);

        vm.prank(receiverHub);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, INVALID_REASON)
        );
        decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));
    }

    function testDecodeVersionNotChecked() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: UNCHECKED_VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeConsistencyLevelNotChecked() public {
        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: UNFINALIZED_CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(decoder.nonce(), 1);
    }

    function testDecodeReceiverHubNotChecked() public {
        WormholeDecoder otherHubDecoder =
            new WormholeDecoder(senderHub, otherReceiverHub, address(wormhole));

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), block.chainid, new Call[](0)),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            true,
            ""
        );

        vm.prank(receiverHub);
        Call[] memory decoded = decoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        vm.prank(otherReceiverHub);
        Call[] memory otherDecoded = otherHubDecoder.decode(
            address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
        );

        assertEq(decoded.length, 0);
        assertEq(otherDecoded.length, 0);
        assertEq(decoder.nonce(), 1);
        assertEq(otherHubDecoder.nonce(), 1);
    }
}
