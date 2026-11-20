// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {SenderHub} from "src/SenderHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IFxMessageProcessor} from "src/interfaces/bridges/IFxMessageProcessor.sol";
import {IFxRoot} from "src/interfaces/bridges/IFxRoot.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {FxDecoder} from "src/modules/fx/FxDecoder.sol";
import {FxEncoder} from "src/modules/fx/FxEncoder.sol";
import {FxError} from "src/modules/fx/FxError.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";
import {IPolygonFxChild} from "test/utils/IPolygonFxChild.sol";
import {IPolygonFxRoot} from "test/utils/IPolygonFxRoot.sol";
import {IPolygonStateReceiver} from "test/utils/IPolygonStateReceiver.sol";
import {IPolygonStateSender} from "test/utils/IPolygonStateSender.sol";
import {IPoolManager} from "test/utils/IPoolManager.sol";
import {PolygonRelayer} from "test/utils/PolygonRelayer.sol";

// Fork blocks are pinned so runs are reproducible and RPC responses are cached. The mainnet block
// is the one the other integration tests pin. The Polygon block is a few minutes older, so that
// it has not committed a state sync the mainnet block has yet to send. Bump them together.
uint256 constant MAINNET_BLOCK = 26_444_000;

uint256 constant POLYGON_CHAIN_ID = 137;
uint256 constant POLYGON_BLOCK = 97_549_000;
address constant POLYGON_FX_ROOT = 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2;
address constant POLYGON_POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;

/// @notice Sends multichain actions from a SenderHub on an Ethereum fork through the real FxRoot of
///         one Polygon chain, then relays the state sync to a ReceiverHub on a fork of that chain.
///         Run once per chain by the contracts below.
abstract contract FxIntegrationTest is Test {
    SenderHub internal senderHub;
    FxEncoder internal encoder;
    ReceiverHub internal receiverHub;
    FxDecoder internal decoder;
    MockTarget internal target;

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    string internal l2RpcAlias;
    uint256 internal immutable L2_CHAIN_ID;
    uint256 internal immutable L2_BLOCK;
    address internal immutable FX_ROOT;
    address internal immutable POOL_MANAGER;

    address internal stateSender;
    address internal fxChild;

    IPolygonStateReceiver internal constant STATE_RECEIVER =
        IPolygonStateReceiver(PolygonRelayer.STATE_RECEIVER);

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");
    address internal bob = makeAddr("bob");
    address internal sink = makeAddr("sink");
    address internal protocolFeeController = makeAddr("protocolFeeController");

    // Gas the StateReceiver's oracle grants a state sync's receiver at the pinned block.
    uint256 internal constant RECEIVER_GAS = 160_000;
    uint256 internal constant MAX_RECEIVER_GAS = 5_000_000;

    // Byte length of the state sync for one call without data, and the longest data that keeps
    // the state sync for one call within what the encoder sends and Heimdall passes on. State
    // sync lengths are multiples of a word, the longest that fits is 29,984 bytes.
    uint256 internal constant EMPTY_CALL_STATE_SYNC_SIZE = 352;
    uint256 internal constant MAX_CALL_DATA_LENGTH = 29_632;

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
        address fxRoot,
        address poolManager
    ) {
        l2RpcAlias = rpcAlias;
        L2_CHAIN_ID = chainId;
        L2_BLOCK = blockNumber;
        FX_ROOT = fxRoot;
        POOL_MANAGER = poolManager;
    }

    function setUp() public {
        l1Fork = vm.createFork("mainnet", MAINNET_BLOCK);
        l2Fork = vm.createFork(l2RpcAlias, L2_BLOCK);

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new FxEncoder(FX_ROOT);
        vm.stopPrank();

        stateSender = IPolygonFxRoot(FX_ROOT).stateSender();
        fxChild = IPolygonFxRoot(FX_ROOT).fxChild();

        vm.selectFork(l2Fork);

        vm.startPrank(remoteAdmin);
        receiverHub = new ReceiverHub();
        decoder = new FxDecoder(address(senderHub), address(receiverHub), fxChild);
        receiverHub.setDecoder(
            IFxMessageProcessor.processMessageFromRoot.selector, address(decoder)
        );
        vm.stopPrank();

        target = new MockTarget();

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

        bytes memory message = abi.encode(calls);
        bytes memory stateData = abi.encode(address(senderHub), address(receiverHub), message);
        uint256 stateId = IPolygonStateSender(stateSender).counter() + 1;

        vm.recordLogs();

        vm.expectEmit(stateSender);
        emit IPolygonStateSender.StateSynced(stateId, fxChild, stateData);

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(L2_CHAIN_ID, FX_ROOT, address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);
        assertEq(syncs[0].id, stateId);
        assertEq(syncs[0].receiver, fxChild);
        assertEq(syncs[0].data, stateData);

        vm.selectFork(l2Fork);

        assertLt(STATE_RECEIVER.lastStateId(), stateId);

        vm.expectCall(address(target), 0, CALL_DATA, 1);

        vm.expectEmit(fxChild);
        emit IPolygonFxChild.NewFxMessage(address(senderHub), address(receiverHub), message);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            fxChild, IFxMessageProcessor.processMessageFromRoot.selector, address(decoder)
        );

        vm.expectEmit(address(STATE_RECEIVER));
        emit IPolygonStateReceiver.StateCommitted(stateId, true);

        bool success = PolygonRelayer.relay(syncs[0]);

        assertTrue(success);
        assertEq(STATE_RECEIVER.lastStateId(), stateId);
        assertEq(STATE_RECEIVER.failedStateSyncHashes(stateId), bytes32(0x00));
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

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);

        vm.selectFork(l2Fork);

        // Three calls to the mock target need more gas than a state sync's receiver gets, see
        // `testRelayExceedsReceiverGasIsReplayable`, so they run in a replay.
        bool committed = PolygonRelayer.relay(syncs[0]);

        assertFalse(committed);
        assertEq(target.callCount(), 0);

        (bool success,) = PolygonRelayer.replay(syncs[0]);

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

        // A state sync carries no value, so the encoder refuses the action before the FxRoot is
        // called.
        vm.prank(admin);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        senderHub.sendMultichainActions{value: FIRST_VALUE}(actions);
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

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);

        vm.selectFork(l2Fork);

        bool success = PolygonRelayer.relay(syncs[0]);

        assertTrue(success);
        assertEq(poolManager.protocolFeeController(), protocolFeeController);
    }

    function testRelayFromOtherL1Contract() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MockTarget impostor = new MockTarget();
        impostor.setReenter(
            FX_ROOT,
            abi.encodeCall(IFxRoot.sendMessageToChild, (address(receiverHub), abi.encode(calls))),
            0
        );

        vm.recordLogs();

        (bool sent,) = address(impostor).call("");

        assertTrue(sent);

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);
        assertEq(
            syncs[0].data, abi.encode(address(impostor), address(receiverHub), abi.encode(calls))
        );

        vm.selectFork(l2Fork);

        bool committed = PolygonRelayer.relay(syncs[0]);

        assertFalse(committed);
        assertEq(target.callCount(), 0);

        // The StateReceiver drops the revert data of a failed state sync, a replay surfaces it.
        (bool success, bytes memory returnData) = PolygonRelayer.replay(syncs[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromEOA() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.recordLogs();

        vm.prank(bob, bob);
        IFxRoot(FX_ROOT).sendMessageToChild(address(receiverHub), abi.encode(calls));

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        // Unlike an OptimismPortal2 or an Inbox, the FxRoot aliases no sender, contract or not.
        assertEq(syncs.length, 1);
        assertEq(syncs[0].data, abi.encode(bob, address(receiverHub), abi.encode(calls)));

        vm.selectFork(l2Fork);

        bool committed = PolygonRelayer.relay(syncs[0]);

        assertFalse(committed);

        (bool success, bytes memory returnData) = PolygonRelayer.replay(syncs[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
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

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);

        vm.selectFork(l2Fork);

        vm.expectEmit(address(STATE_RECEIVER));
        emit IPolygonStateReceiver.StateCommitted(syncs[0].id, false);

        bool committed = PolygonRelayer.relay(syncs[0]);

        // The state sync is committed either way, and the StateReceiver keeps a hash of what
        // failed for anyone to replay.
        assertFalse(committed);
        assertEq(STATE_RECEIVER.lastStateId(), syncs[0].id);
        assertEq(
            STATE_RECEIVER.failedStateSyncHashes(syncs[0].id),
            keccak256(abi.encode(fxChild, syncs[0].data))
        );
        assertEq(target.callCount(), 0);

        (bool success, bytes memory returnData) = PolygonRelayer.replay(syncs[0]);

        // A replay that fails reverts, which leaves the state sync replayable.
        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector,
                address(target),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, 0)
            )
        );
        assertEq(
            STATE_RECEIVER.failedStateSyncHashes(syncs[0].id),
            keccak256(abi.encode(fxChild, syncs[0].data))
        );
        assertEq(target.callCount(), 0);

        target.setRevert(false);

        vm.expectEmit(address(STATE_RECEIVER));
        emit IPolygonStateReceiver.StateSyncReplay(syncs[0].id);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            fxChild, IFxMessageProcessor.processMessageFromRoot.selector, address(decoder)
        );

        vm.prank(bob);
        (success, returnData) = PolygonRelayer.replay(syncs[0]);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(STATE_RECEIVER.failedStateSyncHashes(syncs[0].id), bytes32(0x00));
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);

        // It cannot be replayed again once it has succeeded.
        (success, returnData) = PolygonRelayer.replay(syncs[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSignature("Error(string)", "!found"));
        assertEq(target.callCount(), 1);
    }

    function testRelayExceedsReceiverGasIsReplayable() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});
        calls[1] = Call({target: address(target), value: 0, data: SECOND_DATA});
        calls[2] = Call({target: address(target), value: 0, data: THIRD_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);

        vm.selectFork(l2Fork);

        // Neither the FxRoot nor the encoder has a say in the gas the Receiver Hub runs with, the
        // StateReceiver reads it from an oracle Polygon governs, for every receiver alike.
        assertEq(STATE_RECEIVER.receiverGas(syncs[0].id, fxChild, syncs[0].data), RECEIVER_GAS);
        assertLt(RECEIVER_GAS, MAX_RECEIVER_GAS);

        vm.expectEmit(address(STATE_RECEIVER));
        emit IPolygonStateReceiver.StateCommitted(syncs[0].id, false);

        bool committed = PolygonRelayer.relay(syncs[0]);

        // An action that needs more is accepted on L1 and runs out of gas on Polygon, with none
        // of its calls made.
        assertFalse(committed);
        assertEq(
            STATE_RECEIVER.failedStateSyncHashes(syncs[0].id),
            keccak256(abi.encode(fxChild, syncs[0].data))
        );
        assertEq(target.callCount(), 0);

        // Anyone can then replay it with gas of their own, which the StateReceiver does not cap.
        vm.prank(bob);
        (bool success, bytes memory returnData) = PolygonRelayer.replay(syncs[0]);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(STATE_RECEIVER.failedStateSyncHashes(syncs[0].id), bytes32(0x00));
        assertEq(target.callCount(), 3);
    }

    function testRelayDataAtMaximumIsReplayable() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: sink, value: 0, data: new bytes(MAX_CALL_DATA_LENGTH)});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        // The encoder's limit is the one Heimdall applies.
        assertEq(syncs.length, 1);
        assertEq(syncs[0].data.length, EMPTY_CALL_STATE_SYNC_SIZE + MAX_CALL_DATA_LENGTH);
        assertEq(encoder.MAX_STATE_SYNC_SIZE(), PolygonRelayer.MAX_STATE_SYNC_SIZE);
        assertLe(syncs[0].data.length, PolygonRelayer.MAX_STATE_SYNC_SIZE);
        assertGt(syncs[0].data.length + 32, PolygonRelayer.MAX_STATE_SYNC_SIZE);

        vm.selectFork(l2Fork);

        assertEq(sink.code.length, 0);

        bool committed = PolygonRelayer.relay(syncs[0]);

        // The largest state sync Heimdall passes on reaches Polygon whole, but the FxChild logs
        // every message in full, which alone costs more than the receiver gas at this size, even
        // for a call to an account without code.
        assertFalse(committed);
        assertEq(
            STATE_RECEIVER.failedStateSyncHashes(syncs[0].id),
            keccak256(abi.encode(fxChild, syncs[0].data))
        );

        vm.expectCall(sink, 0, calls[0].data, 1);

        (bool success,) = PolygonRelayer.replay(syncs[0]);

        assertTrue(success);
        assertEq(STATE_RECEIVER.failedStateSyncHashes(syncs[0].id), bytes32(0x00));
    }

    function testSendDataTooLarge() public {
        Call[] memory calls = new Call[](1);
        calls[0] =
            Call({target: address(target), value: 0, data: new bytes(MAX_CALL_DATA_LENGTH + 1)});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        // One byte more of call data takes the state sync a word past the limit, so the encoder
        // refuses the action before the FxRoot is called.
        vm.prank(admin);
        vm.expectRevert(FxError.StateSyncTooLarge.selector);
        senderHub.sendMultichainActions(actions);
    }

    function testRelayDataTooLargeIsDropped() public {
        Call[] memory calls = new Call[](1);
        calls[0] =
            Call({target: address(target), value: 0, data: new bytes(MAX_CALL_DATA_LENGTH + 1)});

        vm.recordLogs();

        // The action `testSendDataTooLarge` shows the encoder refusing, sent to the FxRoot as the
        // Sender Hub to show what the bridge does with it. Neither the FxRoot nor the StateSender
        // checks the size of a message.
        vm.prank(address(senderHub));
        IFxRoot(FX_ROOT).sendMessageToChild(address(receiverHub), abi.encode(calls));

        PolygonRelayer.StateSync[] memory syncs =
            PolygonRelayer.stateSyncs(vm.getRecordedLogs(), stateSender);

        assertEq(syncs.length, 1);
        assertEq(
            syncs[0].data, abi.encode(address(senderHub), address(receiverHub), abi.encode(calls))
        );
        assertEq(syncs[0].data.length, EMPTY_CALL_STATE_SYNC_SIZE + MAX_CALL_DATA_LENGTH + 32);
        assertGt(syncs[0].data.length, PolygonRelayer.MAX_STATE_SYNC_SIZE);

        vm.selectFork(l2Fork);

        vm.expectEmit(address(STATE_RECEIVER));
        emit IPolygonStateReceiver.StateCommitted(syncs[0].id, false);

        bool committed = PolygonRelayer.relay(syncs[0]);

        // Heimdall does, and commits the state sync without its data, which the FxChild cannot
        // decode.
        assertFalse(committed);
        assertEq(
            STATE_RECEIVER.failedStateSyncHashes(syncs[0].id),
            keccak256(abi.encode(fxChild, bytes("")))
        );

        // What failed is the empty state sync, so that is all a replay can run, and the action
        // would be lost.
        (bool success, bytes memory returnData) = PolygonRelayer.replay(syncs[0]);

        assertFalse(success);
        assertEq(returnData.length, 0);

        vm.expectRevert(bytes("!data"));
        STATE_RECEIVER.replayFailedStateSyncWithData(syncs[0].id, fxChild, syncs[0].data);

        assertEq(target.callCount(), 0);
    }
}

contract FxPolygonTest is
    FxIntegrationTest(
        "polygon", POLYGON_CHAIN_ID, POLYGON_BLOCK, POLYGON_FX_ROOT, POLYGON_POOL_MANAGER
    )
{}
