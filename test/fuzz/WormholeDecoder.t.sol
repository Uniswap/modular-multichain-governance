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

struct DecodeInput {
    address caller;
    address receiverHub;
    bool callerIsReceiverHub;
    bool valid;
    bytes32 emitter;
    bool emitterIsSenderHub;
    bool emitterChainIsEthereum;
    uint16 emitterChainId;
    uint32 timestamp;
    uint64 sequence;
    bool nonceMatches;
    uint256 sentNonce;
    bool chainIdMatches;
    uint256 payloadChainId;
    uint256 callCount;
}

contract WormholeDecoderFuzzTest is Test {
    address internal senderHub = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    uint256 internal constant MSG_TIMEOUT = 2 days;
    uint256 internal constant REFERENCE_TIMESTAMP = 1_000_000;

    uint8 internal constant VERSION = 1;
    uint8 internal constant CONSISTENCY_LEVEL = 1;
    uint16 internal constant ETH_WORMHOLE_CHAIN_ID = 2;
    uint16 internal constant WRONG_WORMHOLE_CHAIN_ID = 3;

    string internal constant INVALID_REASON = "bad sig";
    bytes internal constant ENCODED_VM = hex"deadbeef";

    function testFuzzDecode(DecodeInput calldata input) public {
        vm.assume(
            input.receiverHub != VM_ADDRESS && address(uint160(input.receiverHub) ^ 1) != VM_ADDRESS
        );

        vm.warp(REFERENCE_TIMESTAMP);

        bytes32 emitter = input.emitter;
        if (input.emitterIsSenderHub) {
            emitter = bytes32(uint256(uint160(senderHub)));
        } else if (address(uint160(uint256(emitter))) == senderHub) {
            emitter = bytes32(uint256(emitter) ^ 1);
        }

        uint16 emitterChainId =
            input.emitterChainIsEthereum ? ETH_WORMHOLE_CHAIN_ID : input.emitterChainId;
        if (!input.emitterChainIsEthereum && emitterChainId == ETH_WORMHOLE_CHAIN_ID) {
            emitterChainId = WRONG_WORMHOLE_CHAIN_ID;
        }

        uint256 sentNonce = input.nonceMatches ? 0 : input.sentNonce;
        if (!input.nonceMatches && sentNonce == 0) sentNonce = 1;

        uint256 payloadChainId = input.chainIdMatches ? block.chainid : input.payloadChainId;
        if (!input.chainIdMatches && payloadChainId == block.chainid) {
            payloadChainId = block.chainid ^ 1;
        }

        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder decoder =
            new WormholeDecoder(senderHub, input.receiverHub, address(wormhole));

        Call[] memory calls = new Call[](bound(input.callCount, 0, 8));
        for (uint256 i; i < calls.length; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bytes memory expected;
        if (!input.callerIsReceiverHub) {
            expected = abi.encodeWithSelector(IDecoder.CallerNotReceiverHub.selector);
        } else if (!input.valid) {
            expected = abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, INVALID_REASON);
        } else if (address(uint160(uint256(emitter))) != senderHub) {
            expected = abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector);
        } else if (emitterChainId != ETH_WORMHOLE_CHAIN_ID) {
            expected = abi.encodeWithSelector(WormholeError.NotFromEthereum.selector);
        } else if (uint256(input.timestamp) + MSG_TIMEOUT < block.timestamp) {
            expected = abi.encodeWithSelector(WormholeError.Expired.selector);
        } else if (sentNonce != 0) {
            expected = abi.encodeWithSelector(WormholeError.InvalidNonce.selector);
        } else if (payloadChainId != block.chainid) {
            expected = abi.encodeWithSelector(WormholeError.NotToThisChain.selector);
        } else {
            expected = abi.encode(calls);
        }

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: input.timestamp,
                nonce: 0,
                emitterChainId: emitterChainId,
                emitterAddress: emitter,
                sequence: input.sequence,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(sentNonce, payloadChainId, calls),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            input.valid,
            INVALID_REASON
        );

        vm.prank(
            input.callerIsReceiverHub ? input.receiverHub : address(uint160(input.receiverHub) ^ 1)
        );
        (bool success, bytes memory returnData) = address(decoder)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (input.caller, abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)))
                )
            );

        assertEq(returnData, expected);
        assertEq(success, keccak256(expected) == keccak256(abi.encode(calls)));
        assertEq(decoder.nonce(), success ? 1 : 0);
    }

    function testFuzzDecodeSequenceIgnored(DecodeInput calldata input) public {
        vm.warp(REFERENCE_TIMESTAMP);

        address receiverHub = fixedReceiverHub;
        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder withSequence =
            new WormholeDecoder(senderHub, receiverHub, address(wormhole));
        WormholeDecoder withoutSequence =
            new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        Call[] memory calls = new Call[](bound(input.callCount, 0, 8));
        for (uint256 i; i < calls.length; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bool successWith;
        bytes32 returnDataHashWith;
        {
            wormhole.setParseAndVerifyVM(
                VerifiableMessage({
                    version: VERSION,
                    timestamp: input.timestamp,
                    nonce: 0,
                    emitterChainId: input.emitterChainIsEthereum
                        ? ETH_WORMHOLE_CHAIN_ID
                        : input.emitterChainId,
                    emitterAddress: bytes32(uint256(uint160(senderHub))),
                    sequence: input.sequence,
                    consistencyLevel: CONSISTENCY_LEVEL,
                    payload: abi.encode(
                        input.nonceMatches ? uint256(0) : input.sentNonce,
                        input.chainIdMatches ? block.chainid : input.payloadChainId,
                        calls
                    ),
                    guardianSetIndex: 0,
                    signatures: new Signature[](0),
                    hash: bytes32(0)
                }),
                input.valid,
                INVALID_REASON
            );

            vm.prank(receiverHub);
            (bool ok, bytes memory returnData) = address(withSequence)
                .call(
                    abi.encodeCall(
                        IDecoder.decode,
                        (address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)))
                    )
                );

            successWith = ok;
            returnDataHashWith = keccak256(returnData);
        }

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: input.timestamp,
                nonce: 0,
                emitterChainId: input.emitterChainIsEthereum
                    ? ETH_WORMHOLE_CHAIN_ID
                    : input.emitterChainId,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(
                    input.nonceMatches ? uint256(0) : input.sentNonce,
                    input.chainIdMatches ? block.chainid : input.payloadChainId,
                    calls
                ),
                guardianSetIndex: 0,
                signatures: new Signature[](0),
                hash: bytes32(0)
            }),
            input.valid,
            INVALID_REASON
        );

        vm.prank(receiverHub);
        (bool successWithout, bytes memory returnDataWithout) = address(withoutSequence)
            .call(
                abi.encodeCall(
                    IDecoder.decode,
                    (address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)))
                )
            );

        assertEq(successWith, successWithout);
        assertEq(returnDataHashWith, keccak256(returnDataWithout));
        assertEq(withSequence.nonce(), withoutSequence.nonce());
    }

    function testFuzzDecodeExpiry(uint32 timestamp, uint256 warpTo) public {
        warpTo = bound(warpTo, 1, uint256(type(uint32).max) + 2 * MSG_TIMEOUT);

        vm.warp(warpTo);

        address receiverHub = fixedReceiverHub;
        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder decoder = new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: timestamp,
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

        bool notExpired = uint256(timestamp) + MSG_TIMEOUT >= warpTo;

        if (notExpired) {
            vm.prank(receiverHub);
            Call[] memory decoded = decoder.decode(
                address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM))
            );

            assertEq(decoded.length, 0);
            assertEq(decoder.nonce(), 1);
        } else {
            vm.prank(receiverHub);
            vm.expectRevert(WormholeError.Expired.selector);
            decoder.decode(address(0x00), abi.encodeCall(IWormholeCalls.wormholeCall, (ENCODED_VM)));

            assertEq(decoder.nonce(), 0);
        }
    }

    function testFuzzDecodeChainId(uint256 payloadChainId, uint256 blockChainId) public {
        blockChainId = bound(blockChainId, 1, type(uint64).max);

        vm.chainId(blockChainId);

        uint256 mismatched = payloadChainId == blockChainId ? payloadChainId ^ 1 : payloadChainId;

        address receiverHub = fixedReceiverHub;
        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder decoder = new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), mismatched, new Call[](0)),
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

        assertEq(decoder.nonce(), 0);

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(uint256(0), blockChainId, new Call[](0)),
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

    function testFuzzDecodeNonce(uint256 startNonce, uint256 sentNonce) public {
        startNonce = bound(startNonce, 0, type(uint256).max - 1);

        uint256 mismatched = sentNonce == startNonce ? sentNonce ^ 1 : sentNonce;

        address receiverHub = fixedReceiverHub;
        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder decoder = new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        // `nonce` is the only mutable storage variable on the decoder, so it occupies slot 0.
        vm.store(address(decoder), bytes32(0), bytes32(startNonce));

        assertEq(decoder.nonce(), startNonce);

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(mismatched, block.chainid, new Call[](0)),
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

        assertEq(decoder.nonce(), startNonce);

        wormhole.setParseAndVerifyVM(
            VerifiableMessage({
                version: VERSION,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: ETH_WORMHOLE_CHAIN_ID,
                emitterAddress: bytes32(uint256(uint160(senderHub))),
                sequence: 0,
                consistencyLevel: CONSISTENCY_LEVEL,
                payload: abi.encode(startNonce, block.chainid, new Call[](0)),
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
        assertEq(decoder.nonce(), startNonce + 1);
    }

    function testFuzzDecodeShortCalldata(bytes calldata data) public {
        uint256 length = bound(data.length, 0, 3);

        bytes memory short = new bytes(length);
        for (uint256 i; i < length; i++) {
            short[i] = data[i];
        }

        address receiverHub = fixedReceiverHub;
        MockWormhole wormhole = new MockWormhole();
        WormholeDecoder decoder = new WormholeDecoder(senderHub, receiverHub, address(wormhole));

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(address(0x00), short);
    }
}
