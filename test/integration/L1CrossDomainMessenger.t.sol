// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {SenderHub} from "src/SenderHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {
    L1CrossDomainMessengerDecoder
} from "src/modules/optimism-messenger/L1CrossDomainMessengerDecoder.sol";
import {
    L1CrossDomainMessengerEncoder
} from "src/modules/optimism-messenger/L1CrossDomainMessengerEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";
import {IOptimismCrossDomainMessenger} from "test/utils/IOptimismCrossDomainMessenger.sol";
import {IOptimismPortal2} from "test/utils/IOptimismPortal2.sol";
import {IPoolManager} from "test/utils/IPoolManager.sol";
import {OpStackRelayer} from "test/utils/OpStackRelayer.sol";

// Fork blocks are pinned so runs are reproducible and RPC responses are cached, bump them together
// to pick up messenger upgrades.
uint256 constant MAINNET_BLOCK = 26_444_000;

// The L2CrossDomainMessenger is a predeploy, at the same address on every OP Stack chain.
address constant L2_MESSENGER = 0x4200000000000000000000000000000000000007;

uint256 constant OPTIMISM_CHAIN_ID = 10;
uint256 constant OPTIMISM_BLOCK = 159_715_000;
address constant OPTIMISM_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
address constant OPTIMISM_L1_MESSENGER = 0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1;
address constant OPTIMISM_POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;

uint256 constant BASE_CHAIN_ID = 8453;
uint256 constant BASE_BLOCK = 59_201_000;
address constant BASE_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;
address constant BASE_L1_MESSENGER = 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa;
address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

uint256 constant UNICHAIN_CHAIN_ID = 130;
uint256 constant UNICHAIN_BLOCK = 64_281_000;
address constant UNICHAIN_PORTAL = 0x0bd48f6B86a26D3a217d0Fa6FfE2B491B956A7a2;
address constant UNICHAIN_L1_MESSENGER = 0x9A3D64E386C18Cb1d6d5179a9596A4B5736e98A6;
address constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

/// @notice Sends multichain actions from a SenderHub on an Ethereum fork through the real
///         L1CrossDomainMessenger of one OP Stack chain, then relays the deposit it makes to the
///         real L2CrossDomainMessenger on a fork of that chain, which calls a ReceiverHub. Run once
///         per chain by the contracts below.
/// @dev The deposit is relayed by the OP Stack relayer, everything after that is the messenger's
///      own code: the gas the Receiver Hub gets, the failed message it records and the replay. A
///      deposit's calldata is the `relayMessage` call itself, so its hash is the message hash and
///      calling the messenger with it again is the replay.
abstract contract L1CrossDomainMessengerIntegrationTest is Test {
    SenderHub internal senderHub;
    L1CrossDomainMessengerEncoder internal encoder;
    ReceiverHub internal receiverHub;
    L1CrossDomainMessengerDecoder internal decoder;
    MockTarget internal target;

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    string internal l2RpcAlias;
    uint256 internal immutable L2_CHAIN_ID;
    uint256 internal immutable L2_BLOCK;
    address internal immutable PORTAL;
    address internal immutable L1_MESSENGER;
    address internal immutable POOL_MANAGER;

    IOptimismCrossDomainMessenger internal constant L2 =
        IOptimismCrossDomainMessenger(L2_MESSENGER);

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");
    address internal bob = makeAddr("bob");
    address internal protocolFeeController = makeAddr("protocolFeeController");

    address internal aliasedL1Messenger;
    address internal aliasedSenderHub;

    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint32 internal constant MIN_GAS_LIMIT = 1_000_000;
    uint32 internal constant LARGE_MIN_GAS_LIMIT = 10_000_000;
    uint32 internal constant MAX_RESOURCE_LIMIT = 20_000_000;

    uint256 internal constant MAX_DEPOSIT_DATA_LENGTH = 120_000;

    // Calls in the action that runs out of the gas a message without a minimum gas limit gets.
    uint256 internal constant HEAVY_CALL_COUNT = 8;

    uint256 internal constant FUNDING = 10 ether;
    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;

    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";

    constructor(
        string memory rpcAlias,
        uint256 chainId,
        uint256 blockNumber,
        address portal,
        address l1Messenger,
        address poolManager
    ) {
        l2RpcAlias = rpcAlias;
        L2_CHAIN_ID = chainId;
        L2_BLOCK = blockNumber;
        PORTAL = portal;
        L1_MESSENGER = l1Messenger;
        POOL_MANAGER = poolManager;
    }

    function setUp() public {
        l1Fork = vm.createFork("mainnet", MAINNET_BLOCK);
        l2Fork = vm.createFork(l2RpcAlias, L2_BLOCK);

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new L1CrossDomainMessengerEncoder();
        vm.stopPrank();

        aliasedL1Messenger = address(uint160(L1_MESSENGER) + OP_STACK_ALIAS);
        aliasedSenderHub = address(uint160(address(senderHub)) + OP_STACK_ALIAS);

        vm.selectFork(l2Fork);

        vm.startPrank(remoteAdmin);
        receiverHub = new ReceiverHub();
        decoder = new L1CrossDomainMessengerDecoder(
            address(senderHub), address(receiverHub), L2_MESSENGER
        );
        receiverHub.setDecoder(
            ICrossDomainMessengerCalls.crossDomainMessengerCall.selector, address(decoder)
        );
        vm.stopPrank();

        target = new MockTarget();

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub.setEncoder(L2_CHAIN_ID, address(encoder));
        senderHub.setReceiverHub(L2_CHAIN_ID, address(receiverHub));
        encoder.setMessenger(L2_CHAIN_ID, L1_MESSENGER);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);
        vm.stopPrank();

        vm.deal(admin, FUNDING);
    }

    function testSendSingleCall() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message =
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls));

        IOptimismCrossDomainMessenger l1Messenger = IOptimismCrossDomainMessenger(L1_MESSENGER);

        bytes memory relayMessage = abi.encodeCall(
            IOptimismCrossDomainMessenger.relayMessage,
            (
                l1Messenger.messageNonce(),
                address(senderHub),
                address(receiverHub),
                0,
                MIN_GAS_LIMIT,
                message
            )
        );
        uint64 gasLimit = l1Messenger.baseGas(message, MIN_GAS_LIMIT);

        vm.recordLogs();

        vm.expectEmit(PORTAL);
        emit IOptimismPortal2.TransactionDeposited(
            aliasedL1Messenger,
            L2_MESSENGER,
            0,
            abi.encodePacked(uint256(0), uint256(0), gasLimit, false, relayMessage)
        );

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(L2_CHAIN_ID, L1_MESSENGER, address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        // The messenger deposits on the portal in its own name, the Sender Hub only appears
        // inside the message.
        assertEq(deposits.length, 1);
        assertEq(deposits[0].from, aliasedL1Messenger);
        assertEq(deposits[0].to, L2_MESSENGER);
        assertEq(deposits[0].mint, 0);
        assertEq(deposits[0].value, 0);
        assertEq(deposits[0].gasLimit, gasLimit);
        assertGt(deposits[0].gasLimit, MIN_GAS_LIMIT);
        assertFalse(deposits[0].isCreation);
        assertEq(deposits[0].data, relayMessage);

        vm.selectFork(l2Fork);

        bytes32 messageHash = keccak256(deposits[0].data);

        vm.expectCall(address(target), 0, CALL_DATA, 1);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            L2_MESSENGER,
            ICrossDomainMessengerCalls.crossDomainMessengerCall.selector,
            address(decoder)
        );

        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.RelayedMessage(messageHash);

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertTrue(L2.successfulMessages(messageHash));
        assertFalse(L2.failedMessages(messageHash));
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

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertTrue(L2.successfulMessages(keccak256(deposits[0].data)));
        assertEq(target.callCount(), 3);
        assertEq(target.dataAt(0), FIRST_DATA);
        assertEq(target.dataAt(1), SECOND_DATA);
        assertEq(target.dataAt(2), THIRD_DATA);
    }

    function testSendWithValue() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(target), value: FIRST_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: address(target), value: SECOND_VALUE, data: SECOND_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: FIRST_VALUE + SECOND_VALUE}(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].mint, FIRST_VALUE + SECOND_VALUE);
        assertEq(deposits[0].value, FIRST_VALUE + SECOND_VALUE);
        assertEq(admin.balance, FUNDING - FIRST_VALUE - SECOND_VALUE);
        assertEq(address(senderHub).balance, 0);

        vm.selectFork(l2Fork);

        uint256 aliasedBalanceBefore = aliasedL1Messenger.balance;
        uint256 messengerBalanceBefore = L2_MESSENGER.balance;

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertEq(target.callCount(), 2);
        assertEq(target.valueAt(0), FIRST_VALUE);
        assertEq(target.valueAt(1), SECOND_VALUE);
        assertEq(address(target).balance, FIRST_VALUE + SECOND_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(aliasedL1Messenger.balance, aliasedBalanceBefore);
        assertEq(L2_MESSENGER.balance, messengerBalanceBefore);
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

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertEq(poolManager.protocolFeeController(), protocolFeeController);
    }

    function testRelayFromOtherL1Contract() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MockTarget impostor = new MockTarget();
        impostor.setReenter(
            L1_MESSENGER,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    address(receiverHub),
                    abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls)),
                    MIN_GAS_LIMIT
                )
            ),
            0
        );

        vm.recordLogs();

        (bool sent,) = address(impostor).call("");

        assertTrue(sent);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].from, aliasedL1Messenger);
        assertEq(deposits[0].to, L2_MESSENGER);

        vm.selectFork(l2Fork);

        bytes32 messageHash = keccak256(deposits[0].data);

        // The Receiver Hub is called by the messenger all the same, what tells the message apart
        // is the sender the messenger reports. The decoder sees it twice, on the first attempt
        // and on the replay below.
        vm.expectCall(
            address(decoder),
            abi.encodeCall(
                IDecoder.decode,
                (
                    L2_MESSENGER,
                    abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls))
                )
            ),
            2
        );

        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.FailedRelayedMessage(messageHash);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        // The deposit itself succeeds, the messenger records the message as failed.
        assertTrue(success);
        assertTrue(L2.failedMessages(messageHash));
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);

        // Relaying it again fails the same way.
        vm.prank(bob);
        (success,) = L2_MESSENGER.call(deposits[0].data);

        assertTrue(success);
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromEOA() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.recordLogs();

        vm.prank(bob, bob);
        ICrossDomainMessenger(L1_MESSENGER)
            .sendMessage(
                address(receiverHub),
                abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls)),
                MIN_GAS_LIMIT
            );

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].from, aliasedL1Messenger);

        vm.selectFork(l2Fork);

        bytes32 messageHash = keccak256(deposits[0].data);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertTrue(L2.failedMessages(messageHash));
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);
    }

    function testRelayNotFromMessenger() public {
        vm.selectFork(l2Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        bytes memory message =
            abi.encodeCall(ICrossDomainMessengerCalls.crossDomainMessengerCall, (calls));

        // The alias of the Sender Hub is the caller of a deposit it makes on the portal directly,
        // which this decoder does not accept.
        address[2] memory callers = [bob, aliasedSenderHub];

        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            (bool success, bytes memory returnData) = address(receiverHub).call(message);

            assertFalse(success);
            assertEq(returnData, abi.encodeWithSelector(IDecoder.InvalidReceiverHubCaller.selector));
        }

        assertEq(target.callCount(), 0);
    }

    function testRelayFailedCallIsReplayable() public {
        vm.selectFork(l2Fork);

        target.setRevert(true);

        uint256 aliasedBalanceBefore = aliasedL1Messenger.balance;
        uint256 messengerBalanceBefore = L2_MESSENGER.balance;

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: FIRST_VALUE, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: FIRST_VALUE}(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        bytes32 messageHash = keccak256(deposits[0].data);

        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.FailedRelayedMessage(messageHash);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        // The deposit succeeds although the action failed. The messenger records the message and
        // holds the Ether it carries, none of it is stranded on an alias.
        assertTrue(success);
        assertTrue(L2.failedMessages(messageHash));
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);
        assertEq(address(target).balance, 0);
        assertEq(address(receiverHub).balance, 0);
        assertEq(aliasedL1Messenger.balance, aliasedBalanceBefore);
        assertEq(L2_MESSENGER.balance, messengerBalanceBefore + FIRST_VALUE);

        // Anyone can relay it again. While the action still fails, the message stays as it was.
        vm.prank(bob);
        (success,) = L2_MESSENGER.call(deposits[0].data);

        assertTrue(success);
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);
        assertEq(L2_MESSENGER.balance, messengerBalanceBefore + FIRST_VALUE);

        // A replay cannot bring Ether of its own.
        vm.deal(bob, 1);
        vm.prank(bob);
        (success,) = L2_MESSENGER.call{value: 1}(deposits[0].data);

        assertFalse(success);

        target.setRevert(false);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            L2_MESSENGER,
            ICrossDomainMessengerCalls.crossDomainMessengerCall.selector,
            address(decoder)
        );

        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.RelayedMessage(messageHash);

        vm.prank(bob);
        (success,) = L2_MESSENGER.call(deposits[0].data);

        assertTrue(success);
        assertTrue(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);
        assertEq(target.lastValue(), FIRST_VALUE);
        assertEq(address(target).balance, FIRST_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(L2_MESSENGER.balance, messengerBalanceBefore);

        // It cannot be relayed again once it has succeeded.
        vm.prank(bob);
        (success,) = L2_MESSENGER.call(deposits[0].data);

        assertFalse(success);
        assertEq(target.callCount(), 1);
    }

    function testRelayMinGasLimitUnsetIsReplayable() public {
        vm.prank(admin);
        encoder.setMinGasLimit(0);

        Call[] memory calls = new Call[](HEAVY_CALL_COUNT);
        for (uint256 i; i < HEAVY_CALL_COUNT; i++) {
            calls[i] = Call({target: address(target), value: 0, data: abi.encode(i)});
        }

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        // Unlike the portal, the messenger accepts a message without a minimum gas limit, it
        // buys the gas its own overhead needs either way.
        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        bytes32 messageHash = keccak256(deposits[0].data);

        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.FailedRelayedMessage(messageHash);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        // An action that needs more gas than the message bought runs out of it on L2, with none
        // of its calls made.
        assertTrue(success);
        assertTrue(L2.failedMessages(messageHash));
        assertFalse(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), 0);

        // Anyone can then relay it with gas of their own, which the messenger does not cap.
        vm.expectEmit(L2_MESSENGER);
        emit IOptimismCrossDomainMessenger.RelayedMessage(messageHash);

        vm.prank(bob);
        (success,) = L2_MESSENGER.call(deposits[0].data);

        assertTrue(success);
        assertTrue(L2.successfulMessages(messageHash));
        assertEq(target.callCount(), HEAVY_CALL_COUNT);
    }

    function testSendMinGasLimitAboveResourceLimit() public {
        vm.prank(admin);
        encoder.setMinGasLimit(MAX_RESOURCE_LIMIT + 1);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                L1_MESSENGER,
                abi.encodeWithSelector(IOptimismPortal2.OutOfGas.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }

    function testSendCalldataTooLarge() public {
        vm.prank(admin);
        encoder.setMinGasLimit(LARGE_MIN_GAS_LIMIT);

        Call[] memory calls = new Call[](1);
        calls[0] =
            Call({target: address(target), value: 0, data: new bytes(MAX_DEPOSIT_DATA_LENGTH)});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                L1_MESSENGER,
                abi.encodeWithSelector(IOptimismPortal2.OptimismPortal_CalldataTooLarge.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }
}

contract L1CrossDomainMessengerOptimismTest is
    L1CrossDomainMessengerIntegrationTest(
        "optimism",
        OPTIMISM_CHAIN_ID,
        OPTIMISM_BLOCK,
        OPTIMISM_PORTAL,
        OPTIMISM_L1_MESSENGER,
        OPTIMISM_POOL_MANAGER
    )
{}

contract L1CrossDomainMessengerBaseTest is
    L1CrossDomainMessengerIntegrationTest(
        "base", BASE_CHAIN_ID, BASE_BLOCK, BASE_PORTAL, BASE_L1_MESSENGER, BASE_POOL_MANAGER
    )
{}

contract L1CrossDomainMessengerUnichainTest is
    L1CrossDomainMessengerIntegrationTest(
        "unichain",
        UNICHAIN_CHAIN_ID,
        UNICHAIN_BLOCK,
        UNICHAIN_PORTAL,
        UNICHAIN_L1_MESSENGER,
        UNICHAIN_POOL_MANAGER
    )
{}

/// @notice Sends one batch of multichain actions to every OP Stack chain at once and relays each
///         chain's deposit to its own fork.
contract L1CrossDomainMessengerMultichainTest is Test {
    struct Remote {
        uint256 chainId;
        uint256 fork;
        address portal;
        address l1Messenger;
        ReceiverHub receiverHub;
        L1CrossDomainMessengerDecoder decoder;
        MockTarget target;
    }

    SenderHub internal senderHub;
    L1CrossDomainMessengerEncoder internal encoder;

    Remote[] internal remotes;

    uint256 internal l1Fork;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");

    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint32 internal constant MIN_GAS_LIMIT = 1_000_000;

    uint256 internal constant FUNDING = 10 ether;
    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";

    function setUp() public {
        l1Fork = vm.createSelectFork("mainnet", MAINNET_BLOCK);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new L1CrossDomainMessengerEncoder();
        encoder.setMinGasLimit(MIN_GAS_LIMIT);
        vm.stopPrank();

        remotes.push();
        remotes[0].chainId = OPTIMISM_CHAIN_ID;
        remotes[0].fork = vm.createFork("optimism", OPTIMISM_BLOCK);
        remotes[0].portal = OPTIMISM_PORTAL;
        remotes[0].l1Messenger = OPTIMISM_L1_MESSENGER;

        remotes.push();
        remotes[1].chainId = BASE_CHAIN_ID;
        remotes[1].fork = vm.createFork("base", BASE_BLOCK);
        remotes[1].portal = BASE_PORTAL;
        remotes[1].l1Messenger = BASE_L1_MESSENGER;

        remotes.push();
        remotes[2].chainId = UNICHAIN_CHAIN_ID;
        remotes[2].fork = vm.createFork("unichain", UNICHAIN_BLOCK);
        remotes[2].portal = UNICHAIN_PORTAL;
        remotes[2].l1Messenger = UNICHAIN_L1_MESSENGER;

        for (uint256 i; i < remotes.length; i++) {
            vm.selectFork(remotes[i].fork);

            vm.startPrank(remoteAdmin);
            ReceiverHub receiverHub = new ReceiverHub();
            L1CrossDomainMessengerDecoder decoder = new L1CrossDomainMessengerDecoder(
                address(senderHub), address(receiverHub), L2_MESSENGER
            );
            receiverHub.setDecoder(
                ICrossDomainMessengerCalls.crossDomainMessengerCall.selector, address(decoder)
            );
            vm.stopPrank();

            remotes[i].receiverHub = receiverHub;
            remotes[i].decoder = decoder;
            remotes[i].target = new MockTarget();

            vm.selectFork(l1Fork);

            vm.startPrank(admin);
            senderHub.setEncoder(remotes[i].chainId, address(encoder));
            senderHub.setReceiverHub(remotes[i].chainId, address(receiverHub));
            encoder.setMessenger(remotes[i].chainId, remotes[i].l1Messenger);
            vm.stopPrank();
        }

        vm.deal(admin, FUNDING);
    }

    function testSendMultipleChains() public {
        uint256[3] memory values = [FIRST_VALUE, SECOND_VALUE, THIRD_VALUE];
        bytes[3] memory datas = [FIRST_DATA, SECOND_DATA, THIRD_DATA];

        MultichainAction[] memory actions = new MultichainAction[](3);

        for (uint256 i; i < 3; i++) {
            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: address(remotes[i].target), value: values[i], data: datas[i]});

            actions[i] = MultichainAction({chainId: remotes[i].chainId, calls: calls});
        }

        vm.recordLogs();

        for (uint256 i; i < 3; i++) {
            vm.expectEmit(address(senderHub));
            emit ISenderHub.SendMultichainAction(
                remotes[i].chainId, remotes[i].l1Messenger, address(encoder)
            );
        }

        vm.prank(admin);
        senderHub.sendMultichainActions{value: FIRST_VALUE + SECOND_VALUE + THIRD_VALUE}(actions);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(admin.balance, FUNDING - FIRST_VALUE - SECOND_VALUE - THIRD_VALUE);
        assertEq(address(senderHub).balance, 0);

        for (uint256 i; i < 3; i++) {
            OpStackRelayer.Deposit[] memory deposits =
                OpStackRelayer.deposits(logs, remotes[i].portal);

            assertEq(deposits.length, 1);
            assertEq(deposits[0].from, address(uint160(remotes[i].l1Messenger) + OP_STACK_ALIAS));
            assertEq(deposits[0].to, L2_MESSENGER);
            assertEq(deposits[0].mint, values[i]);
            assertEq(deposits[0].value, values[i]);

            vm.selectFork(remotes[i].fork);

            assertEq(block.chainid, remotes[i].chainId);

            vm.expectEmit(address(remotes[i].receiverHub));
            emit IReceiverHub.CallsReceived(
                L2_MESSENGER,
                ICrossDomainMessengerCalls.crossDomainMessengerCall.selector,
                address(remotes[i].decoder)
            );

            (bool success,) = OpStackRelayer.relay(deposits[0]);

            assertTrue(success);
            assertTrue(
                IOptimismCrossDomainMessenger(L2_MESSENGER)
                    .successfulMessages(keccak256(deposits[0].data))
            );
            assertEq(remotes[i].target.callCount(), 1);
            assertEq(remotes[i].target.lastData(), datas[i]);
            assertEq(remotes[i].target.lastValue(), values[i]);
            assertEq(address(remotes[i].target).balance, values[i]);
            assertEq(address(remotes[i].receiverHub).balance, 0);
        }
    }
}
