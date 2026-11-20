// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {SenderHub} from "src/SenderHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IInbox} from "src/interfaces/bridges/IInbox.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IArbitrumCalls} from "src/modules/arbitrum-orbit/IArbitrumCalls.sol";
import {InboxDecoder} from "src/modules/arbitrum-orbit/InboxDecoder.sol";
import {InboxEncoder} from "src/modules/arbitrum-orbit/InboxEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";
import {ArbitrumRelayer} from "test/utils/ArbitrumRelayer.sol";
import {IArbitrumBridge} from "test/utils/IArbitrumBridge.sol";
import {IArbitrumInbox} from "test/utils/IArbitrumInbox.sol";
import {IPoolManager} from "test/utils/IPoolManager.sol";

// Fork blocks are pinned so runs are reproducible and RPC responses are cached. The mainnet block
// is the one the other integration tests pin, bump them together to pick up Inbox upgrades.
uint256 constant MAINNET_BLOCK = 26_444_000;

// Uniswap governance's Timelock. It is a contract on Ethereum, so the Inbox aliases it wherever a
// ticket names it as a refund address.
address constant TIMELOCK = 0x1a9C8182C09F50C8318d769245beA52c32BE35BC;

uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;
uint256 constant ARBITRUM_ONE_BLOCK = 525_408_000;
address constant ARBITRUM_ONE_INBOX = 0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f;
address constant ARBITRUM_ONE_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

/// @notice Sends multichain actions from a SenderHub on an Ethereum fork through the real Inbox of
///         one Arbitrum Orbit chain, then relays the retryable ticket to a ReceiverHub on a fork of
///         that chain. Run once per chain by the contracts below.
abstract contract InboxIntegrationTest is Test {
    SenderHub internal senderHub;
    InboxEncoder internal encoder;
    ReceiverHub internal receiverHub;
    InboxDecoder internal decoder;
    MockTarget internal target;

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    string internal l2RpcAlias;
    uint256 internal immutable L2_CHAIN_ID;
    uint256 internal immutable L2_BLOCK;
    address internal immutable INBOX;
    address internal immutable POOL_MANAGER;

    address internal bridge;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");
    address internal bob = makeAddr("bob");
    address internal protocolFeeController = makeAddr("protocolFeeController");

    address internal aliasedSenderHub;
    address internal aliasedTimelock;

    uint256 internal constant GAS_LIMIT = 1_000_000;
    uint256 internal constant LOW_GAS_LIMIT = 30_000;
    uint256 internal constant MAX_FEE_PER_GAS = 1 gwei;
    uint256 internal constant LOW_MAX_FEE_PER_GAS = 0.001 gwei;
    uint256 internal constant MAX_SUBMISSION_COST = 0.01 ether;
    uint256 internal constant GAS_VALUE = (GAS_LIMIT * MAX_FEE_PER_GAS) + MAX_SUBMISSION_COST;

    uint256 internal constant TICKET_HEADER_LENGTH = 288;

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
        address inbox,
        address poolManager
    ) {
        l2RpcAlias = rpcAlias;
        L2_CHAIN_ID = chainId;
        L2_BLOCK = blockNumber;
        INBOX = inbox;
        POOL_MANAGER = poolManager;
    }

    function setUp() public {
        l1Fork = vm.createFork("mainnet", MAINNET_BLOCK);
        l2Fork = vm.createFork(l2RpcAlias, L2_BLOCK);

        vm.selectFork(l1Fork);

        // The Inbox prices a ticket's submission fee off the L1 base fee, which Forge zeroes
        // inside isolated calls unless a test has set it, so set it to the forked block's.
        vm.fee(block.basefee);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new InboxEncoder(TIMELOCK);
        vm.stopPrank();

        bridge = IArbitrumInbox(INBOX).bridge();

        aliasedSenderHub = ArbitrumRelayer.applyAlias(address(senderHub));
        aliasedTimelock = ArbitrumRelayer.applyAlias(TIMELOCK);

        vm.selectFork(l2Fork);

        vm.startPrank(remoteAdmin);
        receiverHub = new ReceiverHub();
        decoder = new InboxDecoder(address(senderHub), address(receiverHub));
        receiverHub.setDecoder(IArbitrumCalls.arbitrumCall.selector, address(decoder));
        vm.stopPrank();

        target = new MockTarget();

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub.setEncoder(L2_CHAIN_ID, address(encoder));
        senderHub.setReceiverHub(L2_CHAIN_ID, address(receiverHub));
        encoder.setInbox(L2_CHAIN_ID, INBOX);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);
        vm.stopPrank();

        vm.deal(admin, FUNDING);
    }

    function testSendSingleCall() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));
        uint256 messageNum = IArbitrumBridge(bridge).delayedMessageCount();

        vm.recordLogs();

        vm.expectEmit(INBOX);
        emit IArbitrumInbox.InboxMessageDelivered(
            messageNum,
            abi.encodePacked(
                uint256(uint160(address(receiverHub))),
                uint256(0),
                GAS_VALUE,
                MAX_SUBMISSION_COST,
                uint256(uint160(aliasedTimelock)),
                uint256(uint160(aliasedTimelock)),
                GAS_LIMIT,
                MAX_FEE_PER_GAS,
                message.length,
                message
            )
        );

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(L2_CHAIN_ID, INBOX, address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions{value: GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].messageNum, messageNum);
        assertEq(tickets[0].from, aliasedSenderHub);
        assertEq(tickets[0].l1BaseFee, block.basefee);
        assertEq(tickets[0].to, address(receiverHub));
        assertEq(tickets[0].l2CallValue, 0);
        assertEq(tickets[0].deposit, GAS_VALUE);
        assertEq(tickets[0].maxSubmissionCost, MAX_SUBMISSION_COST);
        assertEq(tickets[0].excessFeeRefundAddress, aliasedTimelock);
        assertEq(tickets[0].callValueRefundAddress, aliasedTimelock);
        assertEq(tickets[0].gasLimit, GAS_LIMIT);
        assertEq(tickets[0].maxFeePerGas, MAX_FEE_PER_GAS);
        assertEq(tickets[0].data, message);
        assertEq(admin.balance, FUNDING - GAS_VALUE);
        assertEq(address(senderHub).balance, 0);

        vm.selectFork(l2Fork);

        vm.expectCall(address(target), 0, CALL_DATA, 1);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            aliasedSenderHub, IArbitrumCalls.arbitrumCall.selector, address(decoder)
        );

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        assertTrue(success);
        assertEq(returnData.length, 0);
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
        senderHub.sendMultichainActions{value: GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        assertTrue(success);
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
        senderHub.sendMultichainActions{value: FIRST_VALUE + SECOND_VALUE + GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].l2CallValue, FIRST_VALUE + SECOND_VALUE);
        assertEq(tickets[0].deposit, FIRST_VALUE + SECOND_VALUE + GAS_VALUE);
        assertEq(admin.balance, FUNDING - FIRST_VALUE - SECOND_VALUE - GAS_VALUE);
        assertEq(address(senderHub).balance, 0);

        vm.selectFork(l2Fork);

        uint256 aliasedBalanceBefore = aliasedSenderHub.balance;

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        assertTrue(success);
        assertEq(target.callCount(), 2);
        assertEq(target.valueAt(0), FIRST_VALUE);
        assertEq(target.valueAt(1), SECOND_VALUE);
        assertEq(address(target).balance, FIRST_VALUE + SECOND_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(ArbitrumRelayer.escrow(tickets[0]).balance, 0);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
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
        senderHub.sendMultichainActions{value: GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        assertTrue(success);
        assertEq(poolManager.protocolFeeController(), protocolFeeController);
    }

    function testSendUnfunded() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        // The encoder asks the Sender Hub to forward the gas value, which it does not hold unless
        // the caller sends it along.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISenderHub.CallFail.selector, INBOX, ""));
        senderHub.sendMultichainActions(actions);
    }

    function testRelayRefundsAliasedTimelock() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);

        vm.selectFork(l2Fork);

        uint256 baseFee = block.basefee;
        uint256 aliasedBalanceBefore = aliasedSenderHub.balance;
        uint256 timelockBalanceBefore = TIMELOCK.balance;
        uint256 refundBalanceBefore = aliasedTimelock.balance;

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        // All of the gas value but the gas the call used, at the base fee, comes back on L2. It
        // goes to the Timelock's alias, which only the Timelock can move, by sending a ticket
        // through the Inbox itself.
        assertTrue(success);
        assertGt(baseFee, 0);
        assertLt(baseFee, MAX_FEE_PER_GAS);
        assertGt(
            aliasedTimelock.balance - refundBalanceBefore,
            MAX_SUBMISSION_COST + (GAS_LIMIT * (MAX_FEE_PER_GAS - baseFee))
        );
        assertLt(aliasedTimelock.balance - refundBalanceBefore, GAS_VALUE);
        assertEq(TIMELOCK.balance, timelockBalanceBefore);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
        assertEq(address(receiverHub).balance, 0);
    }

    function testRelayFromOtherL1Contract() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MockTarget impostor = new MockTarget();
        impostor.setReenter(
            INBOX,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    address(receiverHub),
                    0,
                    MAX_SUBMISSION_COST,
                    TIMELOCK,
                    TIMELOCK,
                    GAS_LIMIT,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls))
                )
            ),
            GAS_VALUE
        );

        vm.recordLogs();

        (bool sent,) = address(impostor).call{value: GAS_VALUE}("");

        assertTrue(sent);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].from, ArbitrumRelayer.applyAlias(address(impostor)));
        assertEq(tickets[0].to, address(receiverHub));

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromEOA() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.deal(bob, GAS_VALUE);

        vm.recordLogs();

        vm.prank(bob, bob);
        IInbox(INBOX).createRetryableTicket{value: GAS_VALUE}(
            address(receiverHub),
            0,
            MAX_SUBMISSION_COST,
            bob,
            bob,
            GAS_LIMIT,
            MAX_FEE_PER_GAS,
            abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls))
        );

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        // Unlike an OptimismPortal2, the Inbox aliases the sender of a ticket even if it is not a
        // contract.
        assertEq(tickets.length, 1);
        assertEq(tickets[0].from, ArbitrumRelayer.applyAlias(bob));
        assertEq(tickets[0].to, address(receiverHub));

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFailedCallIsRedeemable() public {
        vm.selectFork(l2Fork);

        target.setRevert(true);

        uint256 aliasedBalanceBefore = aliasedSenderHub.balance;

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: FIRST_VALUE, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: FIRST_VALUE + GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        // The ticket outlives the failed attempt, with its call value held in escrow rather than
        // on the aliased Sender Hub or the Receiver Hub.
        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector,
                address(target),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, 0)
            )
        );
        assertEq(target.callCount(), 0);
        assertEq(address(target).balance, 0);
        assertEq(address(receiverHub).balance, 0);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
        assertEq(ArbitrumRelayer.escrow(tickets[0]).balance, FIRST_VALUE);

        target.setRevert(false);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            aliasedSenderHub, IArbitrumCalls.arbitrumCall.selector, address(decoder)
        );

        (success, returnData) = ArbitrumRelayer.redeem(tickets[0], GAS_LIMIT);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);
        assertEq(target.lastValue(), FIRST_VALUE);
        assertEq(address(target).balance, FIRST_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
        assertEq(ArbitrumRelayer.escrow(tickets[0]).balance, 0);
    }

    function testRelayFailedCallCanceledRefundsAliasedTimelock() public {
        vm.selectFork(l2Fork);

        target.setRevert(true);

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: FIRST_VALUE, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: FIRST_VALUE + GAS_VALUE}(actions);

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].callValueRefundAddress, aliasedTimelock);

        vm.selectFork(l2Fork);

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        assertFalse(success);
        assertEq(ArbitrumRelayer.escrow(tickets[0]).balance, FIRST_VALUE);

        uint256 aliasedBalanceBefore = aliasedSenderHub.balance;
        uint256 timelockBalanceBefore = TIMELOCK.balance;
        uint256 refundBalanceBefore = aliasedTimelock.balance;

        ArbitrumRelayer.cancel(tickets[0]);

        // A ticket that is canceled, or never redeemed before it expires, pays its call value to
        // the Timelock's alias, not to the Timelock, the Receiver Hub or the aliased Sender Hub.
        assertEq(target.callCount(), 0);
        assertEq(address(target).balance, 0);
        assertEq(address(receiverHub).balance, 0);
        assertEq(ArbitrumRelayer.escrow(tickets[0]).balance, 0);
        assertEq(aliasedTimelock.balance, refundBalanceBefore + FIRST_VALUE);
        assertEq(TIMELOCK.balance, timelockBalanceBefore);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
    }

    function testRelayGasLimitTooLow() public {
        vm.prank(admin);
        encoder.setGasParameters(LOW_GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{
            value: (LOW_GAS_LIMIT * MAX_FEE_PER_GAS) + MAX_SUBMISSION_COST
        }(
            actions
        );

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].gasLimit, LOW_GAS_LIMIT);

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        // The Inbox does not check that the gas limit covers the Receiver Hub's execution, so the
        // ticket is accepted on L1 and its first attempt runs out of gas on L2.
        assertFalse(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 0);

        // Anyone can then redeem it with gas of their own.
        (success, returnData) = ArbitrumRelayer.redeem(tickets[0], GAS_LIMIT);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);
    }

    function testRelayMaxFeePerGasBelowBaseFee() public {
        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, LOW_MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));
        uint256 submissionFee =
            IArbitrumInbox(INBOX).calculateRetryableSubmissionFee(message.length, 0);

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{
            value: (GAS_LIMIT * LOW_MAX_FEE_PER_GAS) + MAX_SUBMISSION_COST
        }(
            actions
        );

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].maxFeePerGas, LOW_MAX_FEE_PER_GAS);

        vm.selectFork(l2Fork);

        uint256 refundBalanceBefore = aliasedTimelock.balance;

        (bool success, bytes memory returnData) = ArbitrumRelayer.relay(tickets[0]);

        // The Inbox cannot check the max fee per gas against the L2 base fee, so the ticket is
        // accepted on L1 and created on L2 without an attempt at its call. Only the submission
        // fee is spent, the rest of the gas value is refunded.
        assertFalse(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 0);
        assertLt(LOW_MAX_FEE_PER_GAS, block.basefee);
        assertGt(submissionFee, 0);
        assertEq(
            aliasedTimelock.balance - refundBalanceBefore,
            (GAS_LIMIT * LOW_MAX_FEE_PER_GAS) + MAX_SUBMISSION_COST - submissionFee
        );

        // Anyone can then redeem it with gas of their own.
        (success, returnData) = ArbitrumRelayer.redeem(tickets[0], GAS_LIMIT);

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), CALL_DATA);
    }

    function testSendMaxSubmissionCostAtMinimum() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));
        uint256 submissionFee =
            IArbitrumInbox(INBOX).calculateRetryableSubmissionFee(message.length, 0);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, submissionFee);

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions{value: (GAS_LIMIT * MAX_FEE_PER_GAS) + submissionFee}(
            actions
        );

        ArbitrumRelayer.Ticket[] memory tickets =
            ArbitrumRelayer.tickets(vm.getRecordedLogs(), INBOX);

        assertEq(tickets.length, 1);
        assertEq(tickets[0].maxSubmissionCost, submissionFee);

        vm.selectFork(l2Fork);

        (bool success,) = ArbitrumRelayer.relay(tickets[0]);

        assertTrue(success);
        assertEq(target.callCount(), 1);
    }

    function testSendMaxSubmissionCostBelowMinimum() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));
        uint256 submissionFee =
            IArbitrumInbox(INBOX).calculateRetryableSubmissionFee(message.length, 0);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, submissionFee - 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(
                    IArbitrumInbox.InsufficientSubmissionCost.selector,
                    submissionFee,
                    submissionFee - 1
                )
            )
        );
        senderHub.sendMultichainActions{value: (GAS_LIMIT * MAX_FEE_PER_GAS) + submissionFee - 1}(
            actions
        );
    }

    function testSendGasParametersUnset() public {
        vm.prank(admin);
        encoder.setGasParameters(0, 0, 0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));
        uint256 submissionFee =
            IArbitrumInbox(INBOX).calculateRetryableSubmissionFee(message.length, 0);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(
                    IArbitrumInbox.InsufficientSubmissionCost.selector, submissionFee, 0
                )
            )
        );
        senderHub.sendMultichainActions(actions);
    }

    function testSendGasLimitOne() public {
        vm.prank(admin);
        encoder.setGasParameters(1, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(
                    IArbitrumInbox.RetryableData.selector,
                    address(senderHub),
                    address(receiverHub),
                    0,
                    MAX_FEE_PER_GAS + MAX_SUBMISSION_COST,
                    MAX_SUBMISSION_COST,
                    aliasedTimelock,
                    aliasedTimelock,
                    1,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls))
                )
            )
        );
        senderHub.sendMultichainActions{value: MAX_FEE_PER_GAS + MAX_SUBMISSION_COST}(actions);
    }

    function testSendMaxFeePerGasOne() public {
        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, 1, MAX_SUBMISSION_COST);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(
                    IArbitrumInbox.RetryableData.selector,
                    address(senderHub),
                    address(receiverHub),
                    0,
                    GAS_LIMIT + MAX_SUBMISSION_COST,
                    MAX_SUBMISSION_COST,
                    aliasedTimelock,
                    aliasedTimelock,
                    GAS_LIMIT,
                    1,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls))
                )
            )
        );
        senderHub.sendMultichainActions{value: GAS_LIMIT + MAX_SUBMISSION_COST}(actions);
    }

    function testSendGasLimitTooLarge() public {
        vm.prank(admin);
        encoder.setGasParameters(uint256(type(uint64).max) + 1, 0, MAX_SUBMISSION_COST);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(IArbitrumInbox.GasLimitTooLarge.selector)
            )
        );
        senderHub.sendMultichainActions{value: MAX_SUBMISSION_COST}(actions);
    }

    function testSendCalldataTooLarge() public {
        uint256 maxDataSize = IArbitrumInbox(INBOX).maxDataSize();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: new bytes(maxDataSize)});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IArbitrumCalls.arbitrumCall, (calls));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                INBOX,
                abi.encodeWithSelector(
                    IArbitrumInbox.DataTooLarge.selector,
                    TICKET_HEADER_LENGTH + message.length,
                    maxDataSize
                )
            )
        );
        senderHub.sendMultichainActions{value: GAS_VALUE}(actions);
    }
}

contract InboxArbitrumOneTest is
    InboxIntegrationTest(
        "arbitrum",
        ARBITRUM_ONE_CHAIN_ID,
        ARBITRUM_ONE_BLOCK,
        ARBITRUM_ONE_INBOX,
        ARBITRUM_ONE_POOL_MANAGER
    )
{}
