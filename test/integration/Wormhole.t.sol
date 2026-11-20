// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {SenderHub} from "src/SenderHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IWormhole, VerifiableMessage} from "src/interfaces/bridges/IWormhole.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeDecoder} from "src/modules/wormhole/WormholeDecoder.sol";
import {WormholeEncoder} from "src/modules/wormhole/WormholeEncoder.sol";
import {WormholeError} from "src/modules/wormhole/WormholeError.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";
import {IPoolManager} from "test/utils/IPoolManager.sol";
import {IWormholeCore} from "test/utils/IWormholeCore.sol";
import {WormholeRelayer} from "test/utils/WormholeRelayer.sol";

// Fork blocks are pinned so runs are reproducible and RPC responses are cached. The mainnet block
// is the one the other integration tests pin. The remote blocks are a few minutes younger, so
// that a message is relayed after the block that published it. Bump them together.
uint256 constant MAINNET_BLOCK = 26_444_000;
address constant MAINNET_WORMHOLE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
uint16 constant MAINNET_WORMHOLE_CHAIN_ID = 2;

uint256 constant BNB_CHAIN_ID = 56;
uint256 constant BNB_BLOCK = 134_367_000;
address constant BNB_WORMHOLE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
uint16 constant BNB_WORMHOLE_CHAIN_ID = 4;
address constant BNB_POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;

uint256 constant AVALANCHE_CHAIN_ID = 43114;
uint256 constant AVALANCHE_BLOCK = 100_695_000;
address constant AVALANCHE_WORMHOLE = 0x54a8e5f9c4CbA08F9943965859F6c34eAF03E26c;
uint16 constant AVALANCHE_WORMHOLE_CHAIN_ID = 6;
address constant AVALANCHE_POOL_MANAGER = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;

/// @notice Sends multichain actions from a SenderHub on an Ethereum fork through the real Wormhole
///         core, then relays the message, signed by stand-in guardians, to a ReceiverHub on a fork
///         of one remote chain, where that chain's real core verifies it. Run once per chain by
///         the contracts below.
abstract contract WormholeIntegrationTest is Test {
    SenderHub internal senderHub;
    WormholeEncoder internal encoder;
    ReceiverHub internal receiverHub;
    WormholeDecoder internal decoder;
    MockTarget internal target;

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    string internal l2RpcAlias;
    uint256 internal immutable L2_CHAIN_ID;
    uint256 internal immutable L2_BLOCK;
    address internal immutable L2_WORMHOLE;
    uint16 internal immutable L2_WORMHOLE_CHAIN_ID;
    address internal immutable POOL_MANAGER;

    // The remote core's guardian set, of which the relayer holds the keys.
    uint32 internal guardianSetIndex;
    uint256 internal guardians;
    uint256 internal quorum;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");
    address internal protocolFeeController = makeAddr("protocolFeeController");

    uint8 internal constant CONSISTENCY_LEVEL = 1;
    uint256 internal constant MSG_TIMEOUT = 14 days;
    uint256 internal constant MESSAGE_FEE = 0.001 ether;

    uint256 internal constant GUARDIANS = 19;
    uint256 internal constant QUORUM = 13;

    uint256 internal constant FUNDING = 10 ether;
    uint256 internal constant FIRST_VALUE = 1 ether;

    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";

    constructor(
        string memory rpcAlias,
        uint256 chainId,
        uint256 blockNumber,
        address wormhole,
        uint16 wormholeChainId,
        address poolManager
    ) {
        l2RpcAlias = rpcAlias;
        L2_CHAIN_ID = chainId;
        L2_BLOCK = blockNumber;
        L2_WORMHOLE = wormhole;
        L2_WORMHOLE_CHAIN_ID = wormholeChainId;
        POOL_MANAGER = poolManager;
    }

    function setUp() public {
        l1Fork = vm.createFork("mainnet", MAINNET_BLOCK);
        l2Fork = vm.createFork(l2RpcAlias, L2_BLOCK);

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new WormholeEncoder(MAINNET_WORMHOLE, address(senderHub));
        vm.stopPrank();

        vm.selectFork(l2Fork);

        vm.startPrank(remoteAdmin);
        receiverHub = new ReceiverHub();
        decoder = new WormholeDecoder(address(senderHub), address(receiverHub), L2_WORMHOLE);
        receiverHub.setDecoder(IWormholeCalls.wormholeCall.selector, address(decoder));
        vm.stopPrank();

        target = new MockTarget();

        // The guardians' keys are not ours to sign with, so the remote core's guardian set gets
        // keys the relayer holds. The Ethereum core only publishes, its guardian set stays.
        WormholeRelayer.replaceGuardians(L2_WORMHOLE);

        guardianSetIndex = IWormholeCore(L2_WORMHOLE).getCurrentGuardianSetIndex();
        guardians = IWormholeCore(L2_WORMHOLE).getGuardianSet(guardianSetIndex).keys.length;
        quorum = WormholeRelayer.quorum(guardians);

        assertEq(guardians, GUARDIANS);
        assertEq(quorum, QUORUM);

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub.setEncoder(L2_CHAIN_ID, address(encoder));
        senderHub.setReceiverHub(L2_CHAIN_ID, address(receiverHub));
        vm.stopPrank();

        vm.deal(admin, FUNDING);
    }

    function testSendSingleCall() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory payload = abi.encode(L2_CHAIN_ID, calls);
        uint64 sequence = IWormholeCore(MAINNET_WORMHOLE).nextSequence(address(senderHub));

        assertEq(IWormhole(MAINNET_WORMHOLE).messageFee(), 0);

        vm.recordLogs();

        vm.expectEmit(MAINNET_WORMHOLE);
        emit IWormholeCore.LogMessagePublished(
            address(senderHub), sequence, 0, payload, CONSISTENCY_LEVEL
        );

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(L2_CHAIN_ID, MAINNET_WORMHOLE, address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);
        assertEq(messages[0].nonce, 0);
        assertEq(messages[0].emitterChainId, MAINNET_WORMHOLE_CHAIN_ID);
        assertEq(messages[0].emitterAddress, bytes32(uint256(uint160(address(senderHub)))));
        assertEq(messages[0].sequence, sequence);
        assertEq(messages[0].consistencyLevel, CONSISTENCY_LEVEL);
        assertEq(messages[0].payload, payload);
        assertEq(IWormholeCore(MAINNET_WORMHOLE).nextSequence(address(senderHub)), sequence + 1);
        assertEq(admin.balance, FUNDING);

        vm.selectFork(l2Fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);
        bytes32 hash = WormholeRelayer.hash(messages[0]);

        // The remote core has never seen the message, all it knows is what the guardians signed.
        (VerifiableMessage memory parsed, bool valid, string memory reason) =
            IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);
        assertEq(reason, "");
        assertEq(parsed.hash, hash);
        assertEq(parsed.timestamp, messages[0].timestamp);
        assertEq(parsed.guardianSetIndex, guardianSetIndex);
        assertEq(parsed.signatures.length, QUORUM);
        assertFalse(decoder.consumed(hash));

        vm.expectCall(address(target), 0, CALL_DATA, 1);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(bob, IWormholeCalls.wormholeCall.selector, address(decoder));

        // Anyone can submit it.
        vm.prank(bob);
        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertTrue(decoder.consumed(hash));
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);
        assertEq(target.lastValue(), 0);
    }

    function testSendMultipleCalls() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});
        calls[1] = Call({target: address(target), value: 0, data: SECOND_DATA});
        calls[2] = Call({target: address(target), value: 0, data: THIRD_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 3);
        assertEq(target.dataAt(0), FIRST_DATA);
        assertEq(target.dataAt(1), SECOND_DATA);
        assertEq(target.dataAt(2), THIRD_DATA);
    }

    function testSendWithValue() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: FIRST_VALUE, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        // A published message carries no value, so the encoder refuses the action before the
        // core is called.
        vm.prank(admin);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        senderHub.sendMultichainActions{value: FIRST_VALUE}(actions);
    }

    function testSendWithMessageFee() public {
        // The core charges nothing at the pinned block, Wormhole governance can change that.
        WormholeRelayer.setMessageFee(MAINNET_WORMHOLE, MESSAGE_FEE);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        // The encoder asks the Sender Hub to pay the fee, which it can only do with what it is
        // sent along.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ISenderHub.CallFail.selector, MAINNET_WORMHOLE, bytes(""))
        );
        senderHub.sendMultichainActions(actions);

        uint256 wormholeBalanceBefore = MAINNET_WORMHOLE.balance;

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: MESSAGE_FEE}(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);
        assertEq(MAINNET_WORMHOLE.balance, wormholeBalanceBefore + MESSAGE_FEE);
        assertEq(admin.balance, FUNDING - MESSAGE_FEE);
        assertEq(address(senderHub).balance, 0);

        vm.selectFork(l2Fork);

        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 1);
    }

    function testSendProtocolCall() public {
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        vm.selectFork(l2Fork);

        vm.prank(poolManager.owner());
        poolManager.transferOwnership(address(receiverHub));

        assertNotEq(poolManager.protocolFeeController(), protocolFeeController);

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: POOL_MANAGER,
            value: 0,
            data: abi.encodeCall(IPoolManager.setProtocolFeeController, (protocolFeeController))
        });

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(poolManager.protocolFeeController(), protocolFeeController);
    }

    function testSendIdenticalActions() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](2);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});
        actions[1] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        // Published in the same block with the same payload, the messages still differ by the
        // sequence number the core gave each, and so do their hashes.
        assertEq(messages.length, 2);
        assertEq(messages[0].timestamp, messages[1].timestamp);
        assertEq(messages[0].payload, messages[1].payload);
        assertEq(messages[0].sequence + 1, messages[1].sequence);
        assertNotEq(WormholeRelayer.hash(messages[0]), WormholeRelayer.hash(messages[1]));

        vm.selectFork(l2Fork);

        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);

        (success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[1], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 2);
    }

    function testRelayOutOfOrder() public {
        Call[] memory firstCalls = new Call[](1);
        firstCalls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});

        Call[] memory secondCalls = new Call[](1);
        secondCalls[0] = Call({target: address(target), value: 0, data: SECOND_DATA});

        MultichainAction[] memory actions = new MultichainAction[](2);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: firstCalls});
        actions[1] = MultichainAction({chainId: L2_CHAIN_ID, calls: secondCalls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 2);

        vm.selectFork(l2Fork);

        // Nothing orders the messages on the remote chain, whoever submits them does.
        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[1], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 1);
        assertEq(target.dataAt(0), SECOND_DATA);

        (success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 2);
        assertEq(target.dataAt(1), FIRST_DATA);
    }

    function testRelayTwice() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertTrue(success);
        assertEq(target.callCount(), 1);

        // The core keeps no record of what it verified, a Verifiable Message stays valid.
        (, bool valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        (success, returnData) = WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.AlreadyConsumed.selector));

        // Any quorum of the guardians makes for a valid Verifiable Message, here the last
        // thirteen rather than the first. Its bytes differ, the hash of what they signed does not.
        bytes memory resignedVM =
            WormholeRelayer.sign(messages[0], guardianSetIndex, GUARDIANS - QUORUM, QUORUM);

        assertNotEq(keccak256(resignedVM), keccak256(encodedVM));

        (, valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(resignedVM);

        assertTrue(valid);

        (success, returnData) = WormholeRelayer.relay(address(receiverHub), resignedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.AlreadyConsumed.selector));
        assertEq(target.callCount(), 1);
    }

    function testRelayFailedCallIsReplayable() public {
        vm.selectFork(l2Fork);

        target.setRevert(true);

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);
        bytes32 hash = WormholeRelayer.hash(messages[0]);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        // A failed call reverts the submission as a whole, which leaves the message unconsumed.
        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector,
                address(target),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, 0)
            )
        );
        assertFalse(decoder.consumed(hash));
        assertEq(target.callCount(), 0);

        target.setRevert(false);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(bob, IWormholeCalls.wormholeCall.selector, address(decoder));

        // Anyone can submit it again, for as long as it has not timed out.
        vm.prank(bob);
        (success, returnData) = WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertTrue(decoder.consumed(hash));
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);

        // It cannot be submitted again once it has succeeded.
        (success, returnData) = WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.AlreadyConsumed.selector));
        assertEq(target.callCount(), 1);
    }

    function testRelayAtTimeout() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        // The timeout runs from the timestamp of the Ethereum block that published the message,
        // on the remote chain's clock.
        vm.warp(messages[0].timestamp + MSG_TIMEOUT);

        (bool success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertTrue(success);
        assertEq(target.callCount(), 1);
    }

    function testRelayExpired() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        vm.warp(messages[0].timestamp + MSG_TIMEOUT + 1);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);

        // The core has no notion of a message's age, the decoder does.
        (, bool valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.Expired.selector));

        // The timestamp is part of what the guardians sign, signing again does not renew it.
        (success, returnData) = WormholeRelayer.relay(
            address(receiverHub),
            WormholeRelayer.sign(messages[0], guardianSetIndex, GUARDIANS - QUORUM, QUORUM)
        );

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.Expired.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromOtherL1Contract() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MockTarget impostor = new MockTarget();
        impostor.setReenter(
            MAINNET_WORMHOLE,
            abi.encodeCall(
                IWormhole.publishMessage, (0, abi.encode(L2_CHAIN_ID, calls), CONSISTENCY_LEVEL)
            ),
            0
        );

        vm.recordLogs();

        (bool sent,) = address(impostor).call("");

        assertTrue(sent);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);
        assertEq(messages[0].emitterAddress, bytes32(uint256(uint160(address(impostor)))));
        assertEq(messages[0].payload, abi.encode(L2_CHAIN_ID, calls));

        vm.selectFork(l2Fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);

        // Anyone can publish through the core and the guardians sign whatever it logs, so the
        // remote core vouches for the message. Who published it is for the decoder to check.
        (, bool valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromEOA() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.recordLogs();

        vm.prank(bob, bob);
        IWormhole(MAINNET_WORMHOLE)
            .publishMessage(0, abi.encode(L2_CHAIN_ID, calls), CONSISTENCY_LEVEL);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);
        assertEq(messages[0].emitterAddress, bytes32(uint256(uint160(bob))));

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], L2_WORMHOLE)
        );

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromOtherChain() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.selectFork(l2Fork);

        vm.recordLogs();

        // An account at the Sender Hub's address on another chain, here the remote chain itself,
        // publishes what the Sender Hub would through that chain's core.
        vm.prank(address(senderHub));
        IWormhole(L2_WORMHOLE).publishMessage(0, abi.encode(L2_CHAIN_ID, calls), CONSISTENCY_LEVEL);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), L2_WORMHOLE);

        // Only the chain the guardians observed it on tells the message from the Sender Hub's.
        assertEq(messages.length, 1);
        assertEq(messages[0].emitterAddress, bytes32(uint256(uint160(address(senderHub)))));
        assertEq(messages[0].payload, abi.encode(L2_CHAIN_ID, calls));
        assertEq(messages[0].emitterChainId, L2_WORMHOLE_CHAIN_ID);
        assertNotEq(messages[0].emitterChainId, MAINNET_WORMHOLE_CHAIN_ID);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);

        (, bool valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.NotFromEthereum.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayBelowQuorum() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        // One guardian short of a quorum.
        (bool success, bytes memory returnData) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], guardianSetIndex, 0, QUORUM - 1)
        );

        assertFalse(success);
        assertEq(
            returnData, abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, "no quorum")
        );
        assertEq(target.callCount(), 0);

        (success,) = WormholeRelayer.relay(
            address(receiverHub), WormholeRelayer.sign(messages[0], guardianSetIndex, 0, QUORUM)
        );

        assertTrue(success);
        assertEq(target.callCount(), 1);
    }

    function testRelayNotSignedByGuardians() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        // A message the Sender Hub never published, made up off chain.
        WormholeRelayer.Message memory message = WormholeRelayer.Message({
            timestamp: uint32(vm.getBlockTimestamp()),
            nonce: 0,
            emitterChainId: MAINNET_WORMHOLE_CHAIN_ID,
            emitterAddress: bytes32(uint256(uint160(address(senderHub)))),
            sequence: IWormholeCore(MAINNET_WORMHOLE).nextSequence(address(senderHub)),
            consistencyLevel: CONSISTENCY_LEVEL,
            payload: abi.encode(L2_CHAIN_ID, calls)
        });

        vm.selectFork(l2Fork);

        // A quorum of signatures by keys that are not the guardian set's, here those of a set
        // the remote core does not have.
        bytes memory forgedVM = WormholeRelayer.encode(
            message,
            guardianSetIndex,
            WormholeRelayer.signatures(message, guardianSetIndex + 1, 0, QUORUM)
        );

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), forgedVM);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, "VM signature invalid")
        );
        assertEq(target.callCount(), 0);

        // Signed by the guardians, the same message would run. That they sign nothing the core
        // did not log is all that stands between the two.
        (success,) =
            WormholeRelayer.relay(address(receiverHub), WormholeRelayer.sign(message, L2_WORMHOLE));

        assertTrue(success);
        assertEq(target.callCount(), 1);
    }

    function testRelayForgedPayload() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        Call[] memory forgedCalls = new Call[](1);
        forgedCalls[0] = Call({target: mallory, value: 0, data: CALL_DATA});

        // The guardians' signatures over the Sender Hub's message, attached to that message with
        // other calls in its payload.
        WormholeRelayer.Message memory forged = WormholeRelayer.Message({
            timestamp: messages[0].timestamp,
            nonce: messages[0].nonce,
            emitterChainId: messages[0].emitterChainId,
            emitterAddress: messages[0].emitterAddress,
            sequence: messages[0].sequence,
            consistencyLevel: messages[0].consistencyLevel,
            payload: abi.encode(L2_CHAIN_ID, forgedCalls)
        });

        assertNotEq(WormholeRelayer.hash(forged), WormholeRelayer.hash(messages[0]));

        bytes memory forgedVM = WormholeRelayer.encode(
            forged,
            guardianSetIndex,
            WormholeRelayer.signatures(messages[0], guardianSetIndex, 0, QUORUM)
        );

        vm.expectCall(mallory, CALL_DATA, 0);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), forgedVM);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, "VM signature invalid")
        );
        assertFalse(decoder.consumed(WormholeRelayer.hash(messages[0])));
    }

    function testRelayAfterGuardianSetRotation() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(l2Fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);
        bytes32 hash = WormholeRelayer.hash(messages[0]);

        // The guardian set is replaced before anyone has submitted the message.
        WormholeRelayer.rotateGuardians(L2_WORMHOLE);

        uint256 rotatedAt = vm.getBlockTimestamp();

        assertEq(IWormholeCore(L2_WORMHOLE).getCurrentGuardianSetIndex(), guardianSetIndex + 1);
        assertEq(
            IWormholeCore(L2_WORMHOLE).getGuardianSet(guardianSetIndex).expirationTime,
            rotatedAt + WormholeRelayer.GUARDIAN_SET_EXPIRY
        );

        // The core accepts the replaced set's signatures for another day.
        vm.warp(rotatedAt + WormholeRelayer.GUARDIAN_SET_EXPIRY);

        (, bool valid,) = IWormhole(L2_WORMHOLE).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        vm.warp(rotatedAt + WormholeRelayer.GUARDIAN_SET_EXPIRY + 1);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(receiverHub), encodedVM);

        // After that the Verifiable Message is void, well within the decoder's timeout.
        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(WormholeError.ParseVerifyVM.selector, "guardian set has expired")
        );
        assertLt(vm.getBlockTimestamp(), messages[0].timestamp + MSG_TIMEOUT);
        assertFalse(decoder.consumed(hash));
        assertEq(target.callCount(), 0);

        // The message is not, the new set can sign it, which changes the Verifiable Message but
        // not the hash the decoder goes by.
        bytes memory resignedVM = WormholeRelayer.sign(messages[0], L2_WORMHOLE);

        (VerifiableMessage memory parsed, bool resignedValid,) =
            IWormhole(L2_WORMHOLE).parseAndVerifyVM(resignedVM);

        assertTrue(resignedValid);
        assertEq(parsed.guardianSetIndex, guardianSetIndex + 1);
        assertEq(parsed.hash, hash);

        (success,) = WormholeRelayer.relay(address(receiverHub), resignedVM);

        assertTrue(success);
        assertTrue(decoder.consumed(hash));
        assertEq(target.callCount(), 1);
    }
}

contract WormholeBnbTest is
    WormholeIntegrationTest(
        "bnb", BNB_CHAIN_ID, BNB_BLOCK, BNB_WORMHOLE, BNB_WORMHOLE_CHAIN_ID, BNB_POOL_MANAGER
    )
{}

contract WormholeAvalancheTest is
    WormholeIntegrationTest(
        "avalanche",
        AVALANCHE_CHAIN_ID,
        AVALANCHE_BLOCK,
        AVALANCHE_WORMHOLE,
        AVALANCHE_WORMHOLE_CHAIN_ID,
        AVALANCHE_POOL_MANAGER
    )
{}

/// @notice Sends one batch of multichain actions to every remote chain at once, through the one
///         Wormhole core on Ethereum, and relays each chain's message to its own fork.
contract WormholeMultichainTest is Test {
    struct Remote {
        uint256 chainId;
        uint256 fork;
        address wormhole;
        ReceiverHub receiverHub;
        WormholeDecoder decoder;
        MockTarget target;
    }

    SenderHub internal senderHub;
    WormholeEncoder internal encoder;

    Remote[] internal remotes;

    uint256 internal l1Fork;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";

    function setUp() public {
        l1Fork = vm.createSelectFork("mainnet", MAINNET_BLOCK);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new WormholeEncoder(MAINNET_WORMHOLE, address(senderHub));
        vm.stopPrank();

        remotes.push();
        remotes[0].chainId = BNB_CHAIN_ID;
        remotes[0].fork = vm.createFork("bnb", BNB_BLOCK);
        remotes[0].wormhole = BNB_WORMHOLE;

        remotes.push();
        remotes[1].chainId = AVALANCHE_CHAIN_ID;
        remotes[1].fork = vm.createFork("avalanche", AVALANCHE_BLOCK);
        remotes[1].wormhole = AVALANCHE_WORMHOLE;

        for (uint256 i; i < remotes.length; i++) {
            vm.selectFork(remotes[i].fork);

            vm.startPrank(remoteAdmin);
            ReceiverHub receiverHub = new ReceiverHub();
            WormholeDecoder decoder =
                new WormholeDecoder(address(senderHub), address(receiverHub), remotes[i].wormhole);
            receiverHub.setDecoder(IWormholeCalls.wormholeCall.selector, address(decoder));
            vm.stopPrank();

            remotes[i].receiverHub = receiverHub;
            remotes[i].decoder = decoder;
            remotes[i].target = new MockTarget();

            // Every core has the same guardian set, so every fork gets the same stand-ins.
            WormholeRelayer.replaceGuardians(remotes[i].wormhole);

            vm.selectFork(l1Fork);

            vm.startPrank(admin);
            senderHub.setEncoder(remotes[i].chainId, address(encoder));
            senderHub.setReceiverHub(remotes[i].chainId, address(receiverHub));
            vm.stopPrank();
        }
    }

    function testSendMultipleChains() public {
        bytes[2] memory datas = [FIRST_DATA, SECOND_DATA];

        MultichainAction[] memory actions = new MultichainAction[](2);

        for (uint256 i; i < 2; i++) {
            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: address(remotes[i].target), value: 0, data: datas[i]});

            actions[i] = MultichainAction({chainId: remotes[i].chainId, calls: calls});
        }

        uint64 sequence = IWormholeCore(MAINNET_WORMHOLE).nextSequence(address(senderHub));

        vm.recordLogs();

        for (uint256 i; i < 2; i++) {
            vm.expectEmit(address(senderHub));
            emit ISenderHub.SendMultichainAction(
                remotes[i].chainId, MAINNET_WORMHOLE, address(encoder)
            );
        }

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        // One core takes the messages for every chain, each names its chain in its payload.
        assertEq(messages.length, 2);

        for (uint256 i; i < 2; i++) {
            assertEq(messages[i].sequence, sequence + i);
            assertEq(messages[i].payload, abi.encode(remotes[i].chainId, actions[i].calls));

            vm.selectFork(remotes[i].fork);

            assertEq(block.chainid, remotes[i].chainId);

            bytes memory encodedVM = WormholeRelayer.sign(messages[i], remotes[i].wormhole);

            vm.expectEmit(address(remotes[i].receiverHub));
            emit IReceiverHub.CallsReceived(
                address(this), IWormholeCalls.wormholeCall.selector, address(remotes[i].decoder)
            );

            (bool success,) = WormholeRelayer.relay(address(remotes[i].receiverHub), encodedVM);

            assertTrue(success);
            assertEq(remotes[i].target.callCount(), 1);
            assertEq(remotes[i].target.lastData(), datas[i]);
        }
    }

    function testRelayToOtherChain() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(remotes[0].target), value: 0, data: FIRST_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: remotes[0].chainId, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        WormholeRelayer.Message[] memory messages =
            WormholeRelayer.messages(vm.getRecordedLogs(), MAINNET_WORMHOLE);

        assertEq(messages.length, 1);

        vm.selectFork(remotes[1].fork);

        bytes memory encodedVM = WormholeRelayer.sign(messages[0], remotes[1].wormhole);

        // A Verifiable Message is not addressed to a chain, the core of any chain with that
        // guardian set verifies it. The chain id in the payload is what keeps an action for one
        // chain from running on another.
        (, bool valid,) = IWormhole(remotes[1].wormhole).parseAndVerifyVM(encodedVM);

        assertTrue(valid);

        (bool success, bytes memory returnData) =
            WormholeRelayer.relay(address(remotes[1].receiverHub), encodedVM);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(WormholeError.NotToThisChain.selector));
        assertFalse(remotes[1].decoder.consumed(WormholeRelayer.hash(messages[0])));

        vm.selectFork(remotes[0].fork);

        // The very same bytes run on the chain they are for.
        (success,) = WormholeRelayer.relay(address(remotes[0].receiverHub), encodedVM);

        assertTrue(success);
        assertEq(remotes[0].target.callCount(), 1);
        assertEq(remotes[0].target.lastData(), FIRST_DATA);
    }
}
