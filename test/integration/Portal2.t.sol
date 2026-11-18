// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {SenderHub} from "src/SenderHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IPortal2Calls} from "src/modules/optimism-portal2/IPortal2Calls.sol";
import {Portal2Decoder} from "src/modules/optimism-portal2/Portal2Decoder.sol";
import {Portal2Encoder} from "src/modules/optimism-portal2/Portal2Encoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";
import {IOptimismPortal2} from "test/utils/IOptimismPortal2.sol";
import {IUniswapV3Factory} from "test/utils/IUniswapV3Factory.sol";
import {OpStackRelayer} from "test/utils/OpStackRelayer.sol";

// Fork blocks are pinned so runs are reproducible and RPC responses are cached. Bump them together
// to pick up portal upgrades.
uint256 constant MAINNET_BLOCK = 26_444_000;

uint256 constant OPTIMISM_CHAIN_ID = 10;
uint256 constant OPTIMISM_BLOCK = 159_715_000;
address constant OPTIMISM_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
address constant OPTIMISM_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

uint256 constant BASE_CHAIN_ID = 8453;
uint256 constant BASE_BLOCK = 59_201_000;
address constant BASE_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;
address constant BASE_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

uint256 constant UNICHAIN_CHAIN_ID = 130;
uint256 constant UNICHAIN_BLOCK = 64_281_000;
address constant UNICHAIN_PORTAL = 0x0bd48f6B86a26D3a217d0Fa6FfE2B491B956A7a2;
address constant UNICHAIN_V3_FACTORY = 0x1F98400000000000000000000000000000000003;

/// @notice Sends multichain actions from a SenderHub on an Ethereum fork through the real
///         OptimismPortal2 of one OP Stack chain, then relays the deposit to a ReceiverHub on a
///         fork of that chain. Run once per chain by the contracts below.
abstract contract Portal2IntegrationTest is Test {
    SenderHub internal senderHub;
    Portal2Encoder internal encoder;
    ReceiverHub internal receiverHub;
    Portal2Decoder internal decoder;
    MockTarget internal target;

    uint256 internal l1Fork;
    uint256 internal l2Fork;

    string internal l2RpcAlias;
    uint256 internal immutable L2_CHAIN_ID;
    uint256 internal immutable L2_BLOCK;
    address internal immutable PORTAL;
    address internal immutable V3_FACTORY;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");
    address internal bob = makeAddr("bob");

    address internal aliasedSenderHub;

    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint64 internal constant GAS_LIMIT = 1_000_000;
    uint64 internal constant LARGE_GAS_LIMIT = 10_000_000;
    uint64 internal constant MAX_RESOURCE_LIMIT = 20_000_000;

    uint256 internal constant MAX_DEPOSIT_DATA_LENGTH = 120_000;

    uint256 internal constant FUNDING = 10 ether;
    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;

    uint24 internal constant NEW_FEE = 250;
    int24 internal constant NEW_TICK_SPACING = 5;

    bytes internal constant CALL_DATA = hex"dead";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";

    constructor(
        string memory rpcAlias,
        uint256 chainId,
        uint256 blockNumber,
        address portal,
        address v3Factory
    ) {
        l2RpcAlias = rpcAlias;
        L2_CHAIN_ID = chainId;
        L2_BLOCK = blockNumber;
        PORTAL = portal;
        V3_FACTORY = v3Factory;
    }

    function setUp() public {
        l1Fork = vm.createFork("mainnet", MAINNET_BLOCK);
        l2Fork = vm.createFork(l2RpcAlias, L2_BLOCK);

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub = new SenderHub();
        encoder = new Portal2Encoder();
        vm.stopPrank();

        aliasedSenderHub = address(uint160(address(senderHub)) + OP_STACK_ALIAS);

        vm.selectFork(l2Fork);

        vm.startPrank(remoteAdmin);
        receiverHub = new ReceiverHub();
        decoder = new Portal2Decoder(address(senderHub), address(receiverHub));
        receiverHub.setDecoder(IPortal2Calls.portal2Call.selector, address(decoder));
        vm.stopPrank();

        target = new MockTarget();

        vm.selectFork(l1Fork);

        vm.startPrank(admin);
        senderHub.setEncoder(L2_CHAIN_ID, address(encoder));
        senderHub.setReceiverHub(L2_CHAIN_ID, address(receiverHub));
        encoder.setPortal(L2_CHAIN_ID, PORTAL);
        encoder.setGasLimit(GAS_LIMIT);
        vm.stopPrank();

        vm.deal(admin, FUNDING);
    }

    function testSendSingleCall() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IPortal2Calls.portal2Call, (calls));

        vm.recordLogs();

        vm.expectEmit(PORTAL);
        emit IOptimismPortal2.TransactionDeposited(
            aliasedSenderHub,
            address(receiverHub),
            0,
            abi.encodePacked(uint256(0), uint256(0), GAS_LIMIT, false, message)
        );

        vm.expectEmit(address(senderHub));
        emit ISenderHub.SendMultichainAction(L2_CHAIN_ID, PORTAL, address(encoder));

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].from, aliasedSenderHub);
        assertEq(deposits[0].to, address(receiverHub));
        assertEq(deposits[0].mint, 0);
        assertEq(deposits[0].value, 0);
        assertEq(deposits[0].gasLimit, GAS_LIMIT);
        assertFalse(deposits[0].isCreation);
        assertEq(deposits[0].data, message);

        vm.selectFork(l2Fork);

        vm.expectCall(address(target), 0, CALL_DATA, 1);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(
            aliasedSenderHub, IPortal2Calls.portal2Call.selector, address(decoder)
        );

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

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
        senderHub.sendMultichainActions(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        (bool success,) = OpStackRelayer.relay(deposits[0]);

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
        senderHub.sendMultichainActions{value: FIRST_VALUE + SECOND_VALUE}(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].mint, FIRST_VALUE + SECOND_VALUE);
        assertEq(deposits[0].value, FIRST_VALUE + SECOND_VALUE);
        assertEq(admin.balance, FUNDING - FIRST_VALUE - SECOND_VALUE);
        assertEq(address(senderHub).balance, 0);

        vm.selectFork(l2Fork);

        uint256 aliasedBalanceBefore = aliasedSenderHub.balance;

        (bool success,) = OpStackRelayer.relay(deposits[0]);

        assertTrue(success);
        assertEq(target.callCount(), 2);
        assertEq(target.valueAt(0), FIRST_VALUE);
        assertEq(target.valueAt(1), SECOND_VALUE);
        assertEq(address(target).balance, FIRST_VALUE + SECOND_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore);
    }

    function testSendProtocolCall() public {
        IUniswapV3Factory factory = IUniswapV3Factory(V3_FACTORY);

        vm.selectFork(l2Fork);

        vm.prank(factory.owner());
        factory.setOwner(address(receiverHub));

        assertEq(factory.feeAmountTickSpacing(NEW_FEE), 0);

        vm.selectFork(l1Fork);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: V3_FACTORY,
            value: 0,
            data: abi.encodeCall(IUniswapV3Factory.enableFeeAmount, (NEW_FEE, NEW_TICK_SPACING))
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
        assertEq(factory.feeAmountTickSpacing(NEW_FEE), NEW_TICK_SPACING);
    }

    function testRelayFromOtherL1Contract() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MockTarget impostor = new MockTarget();
        impostor.setReenter(
            PORTAL,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    address(receiverHub),
                    0,
                    GAS_LIMIT,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (calls))
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
        assertEq(deposits[0].from, address(uint160(address(impostor)) + OP_STACK_ALIAS));
        assertEq(deposits[0].to, address(receiverHub));

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFromEOA() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        vm.recordLogs();

        vm.prank(bob, bob);
        IPortal2(PORTAL)
            .depositTransaction(
                address(receiverHub),
                0,
                GAS_LIMIT,
                false,
                abi.encodeCall(IPortal2Calls.portal2Call, (calls))
            );

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].from, bob);
        assertEq(deposits[0].to, address(receiverHub));

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.NotFromSenderHub.selector));
        assertEq(target.callCount(), 0);
    }

    function testRelayFailedCallStrandsValue() public {
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
        senderHub.sendMultichainActions{value: FIRST_VALUE}(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

        // The deposit is spent on L1 and cannot be replayed, and the Ether it minted stays on the
        // aliased Sender Hub rather than reaching the Receiver Hub.
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
        assertEq(aliasedSenderHub.balance, aliasedBalanceBefore + FIRST_VALUE);
    }

    function testRelayGasLimitAtMinimum() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IPortal2Calls.portal2Call, (calls));
        uint64 minimumGasLimit = IOptimismPortal2(PORTAL).minimumGasLimit(uint64(message.length));

        vm.prank(admin);
        encoder.setGasLimit(minimumGasLimit);

        vm.recordLogs();

        vm.prank(admin);
        senderHub.sendMultichainActions(actions);

        OpStackRelayer.Deposit[] memory deposits =
            OpStackRelayer.deposits(vm.getRecordedLogs(), PORTAL);

        assertEq(deposits.length, 1);
        assertEq(deposits[0].gasLimit, minimumGasLimit);

        vm.selectFork(l2Fork);

        (bool success, bytes memory returnData) = OpStackRelayer.relay(deposits[0]);

        // The portal's minimum only covers the deposit's calldata, not the Receiver Hub's
        // execution, so the deposit is accepted on L1 and runs out of gas on L2.
        assertFalse(success);
        assertEq(returnData.length, 0);
        assertEq(target.callCount(), 0);
    }

    function testSendGasLimitBelowMinimum() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        bytes memory message = abi.encodeCall(IPortal2Calls.portal2Call, (calls));
        uint64 minimumGasLimit = IOptimismPortal2(PORTAL).minimumGasLimit(uint64(message.length));

        vm.prank(admin);
        encoder.setGasLimit(minimumGasLimit - 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                PORTAL,
                abi.encodeWithSelector(IOptimismPortal2.OptimismPortal_GasLimitTooLow.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }

    function testSendGasLimitUnset() public {
        vm.prank(admin);
        encoder.setGasLimit(0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                PORTAL,
                abi.encodeWithSelector(IOptimismPortal2.OptimismPortal_GasLimitTooLow.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }

    function testSendGasLimitAboveResourceLimit() public {
        vm.prank(admin);
        encoder.setGasLimit(MAX_RESOURCE_LIMIT + 1);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                PORTAL,
                abi.encodeWithSelector(IOptimismPortal2.OutOfGas.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }

    function testSendCalldataTooLarge() public {
        vm.prank(admin);
        encoder.setGasLimit(LARGE_GAS_LIMIT);

        Call[] memory calls = new Call[](1);
        calls[0] =
            Call({target: address(target), value: 0, data: new bytes(MAX_DEPOSIT_DATA_LENGTH)});

        MultichainAction[] memory actions = new MultichainAction[](1);
        actions[0] = MultichainAction({chainId: L2_CHAIN_ID, calls: calls});

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenderHub.CallFail.selector,
                PORTAL,
                abi.encodeWithSelector(IOptimismPortal2.OptimismPortal_CalldataTooLarge.selector)
            )
        );
        senderHub.sendMultichainActions(actions);
    }
}

contract Portal2OptimismTest is
    Portal2IntegrationTest(
        "optimism", OPTIMISM_CHAIN_ID, OPTIMISM_BLOCK, OPTIMISM_PORTAL, OPTIMISM_V3_FACTORY
    )
{}

contract Portal2BaseTest is
    Portal2IntegrationTest("base", BASE_CHAIN_ID, BASE_BLOCK, BASE_PORTAL, BASE_V3_FACTORY)
{}

contract Portal2UnichainTest is
    Portal2IntegrationTest(
        "unichain", UNICHAIN_CHAIN_ID, UNICHAIN_BLOCK, UNICHAIN_PORTAL, UNICHAIN_V3_FACTORY
    )
{}

/// @notice Sends one batch of multichain actions to every OP Stack chain at once and relays each
///         chain's deposit to its own fork.
contract Portal2MultichainTest is Test {
    struct Remote {
        uint256 chainId;
        uint256 fork;
        address portal;
        ReceiverHub receiverHub;
        Portal2Decoder decoder;
        MockTarget target;
    }

    SenderHub internal senderHub;
    Portal2Encoder internal encoder;

    Remote[] internal remotes;

    uint256 internal l1Fork;

    address internal admin = makeAddr("admin");
    address internal remoteAdmin = makeAddr("remoteAdmin");

    address internal aliasedSenderHub;

    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    uint64 internal constant GAS_LIMIT = 1_000_000;

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
        encoder = new Portal2Encoder();
        encoder.setGasLimit(GAS_LIMIT);
        vm.stopPrank();

        aliasedSenderHub = address(uint160(address(senderHub)) + OP_STACK_ALIAS);

        remotes.push();
        remotes[0].chainId = OPTIMISM_CHAIN_ID;
        remotes[0].fork = vm.createFork("optimism", OPTIMISM_BLOCK);
        remotes[0].portal = OPTIMISM_PORTAL;

        remotes.push();
        remotes[1].chainId = BASE_CHAIN_ID;
        remotes[1].fork = vm.createFork("base", BASE_BLOCK);
        remotes[1].portal = BASE_PORTAL;

        remotes.push();
        remotes[2].chainId = UNICHAIN_CHAIN_ID;
        remotes[2].fork = vm.createFork("unichain", UNICHAIN_BLOCK);
        remotes[2].portal = UNICHAIN_PORTAL;

        for (uint256 i; i < remotes.length; i++) {
            vm.selectFork(remotes[i].fork);

            vm.startPrank(remoteAdmin);
            ReceiverHub receiverHub = new ReceiverHub();
            Portal2Decoder decoder = new Portal2Decoder(address(senderHub), address(receiverHub));
            receiverHub.setDecoder(IPortal2Calls.portal2Call.selector, address(decoder));
            vm.stopPrank();

            remotes[i].receiverHub = receiverHub;
            remotes[i].decoder = decoder;
            remotes[i].target = new MockTarget();

            vm.selectFork(l1Fork);

            vm.startPrank(admin);
            senderHub.setEncoder(remotes[i].chainId, address(encoder));
            senderHub.setReceiverHub(remotes[i].chainId, address(receiverHub));
            encoder.setPortal(remotes[i].chainId, remotes[i].portal);
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
                remotes[i].chainId, remotes[i].portal, address(encoder)
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
            assertEq(deposits[0].from, aliasedSenderHub);
            assertEq(deposits[0].to, address(remotes[i].receiverHub));
            assertEq(deposits[0].mint, values[i]);
            assertEq(deposits[0].value, values[i]);

            vm.selectFork(remotes[i].fork);

            assertEq(block.chainid, remotes[i].chainId);

            vm.expectEmit(address(remotes[i].receiverHub));
            emit IReceiverHub.CallsReceived(
                aliasedSenderHub, IPortal2Calls.portal2Call.selector, address(remotes[i].decoder)
            );

            (bool success,) = OpStackRelayer.relay(deposits[0]);

            assertTrue(success);
            assertEq(remotes[i].target.callCount(), 1);
            assertEq(remotes[i].target.lastData(), datas[i]);
            assertEq(remotes[i].target.lastValue(), values[i]);
            assertEq(address(remotes[i].target).balance, values[i]);
            assertEq(address(remotes[i].receiverHub).balance, 0);
        }
    }
}
