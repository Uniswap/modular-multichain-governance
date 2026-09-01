// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test, stdError} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IInbox} from "src/interfaces/bridges/IInbox.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IArbitrumCalls} from "src/modules/arbitrum-orbit/IArbitrumCalls.sol";
import {InboxEncoder} from "src/modules/arbitrum-orbit/InboxEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract InboxEncoderTest is Test {
    InboxEncoder internal encoder;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal timelock = vm.addr(3);
    address internal receiverHub = vm.addr(4);
    address internal inbox = vm.addr(5);
    address internal otherInbox = vm.addr(6);
    address internal callTargetA = vm.addr(7);
    address internal callTargetB = vm.addr(8);
    address internal callTargetC = vm.addr(9);

    uint256 internal constant CHAIN_ID = 42161;
    uint256 internal constant OTHER_CHAIN_ID = 8453;

    uint256 internal constant GAS_LIMIT = 1_000_000;
    uint256 internal constant MAX_FEE_PER_GAS = 2 gwei;
    uint256 internal constant MAX_SUBMISSION_COST = 0.01 ether;
    uint256 internal constant GAS_VALUE = (GAS_LIMIT * MAX_FEE_PER_GAS) + MAX_SUBMISSION_COST;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";

    function setUp() public {
        vm.prank(admin);
        encoder = new InboxEncoder(timelock);
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        InboxEncoder fresh = new InboxEncoder(timelock);

        assertEq(fresh.TIMELOCK(), timelock);
        assertEq(fresh.owner(), admin);
        assertEq(fresh.gasLimit(), 0);
        assertEq(fresh.maxFeePerGas(), 0);
        assertEq(fresh.maxSubmissionCost(), 0);
        assertEq(fresh.inboxes(CHAIN_ID), address(0x00));
    }

    function testSetGasParameters() public {
        vm.expectEmit(address(encoder));
        emit InboxEncoder.SetGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        assertEq(encoder.gasLimit(), GAS_LIMIT);
        assertEq(encoder.maxFeePerGas(), MAX_FEE_PER_GAS);
        assertEq(encoder.maxSubmissionCost(), MAX_SUBMISSION_COST);
    }

    function testSetGasParametersZero() public {
        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        vm.expectEmit(address(encoder));
        emit InboxEncoder.SetGasParameters(0, 0, 0);

        vm.prank(admin);
        encoder.setGasParameters(0, 0, 0);

        assertEq(encoder.gasLimit(), 0);
        assertEq(encoder.maxFeePerGas(), 0);
        assertEq(encoder.maxSubmissionCost(), 0);
    }

    function testSetGasParametersNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        assertEq(encoder.gasLimit(), 0);
        assertEq(encoder.maxFeePerGas(), 0);
        assertEq(encoder.maxSubmissionCost(), 0);
    }

    function testSetInbox() public {
        vm.expectEmit(address(encoder));
        emit InboxEncoder.SetInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        assertEq(encoder.inboxes(CHAIN_ID), inbox);
    }

    function testSetInboxOverwrite() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.expectEmit(address(encoder));
        emit InboxEncoder.SetInbox(CHAIN_ID, otherInbox);

        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, otherInbox);

        assertEq(encoder.inboxes(CHAIN_ID), otherInbox);
    }

    function testSetInboxZeroAddress() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.expectEmit(address(encoder));
        emit InboxEncoder.SetInbox(CHAIN_ID, address(0x00));

        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, address(0x00));

        assertEq(encoder.inboxes(CHAIN_ID), address(0x00));
    }

    function testSetInboxNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setInbox(CHAIN_ID, inbox);

        assertEq(encoder.inboxes(CHAIN_ID), address(0x00));
    }

    function testEncode() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: FIRST_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, inbox);
        assertEq(bridgeCalls[0].value, THIRD_VALUE + GAS_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    THIRD_VALUE,
                    MAX_SUBMISSION_COST,
                    timelock,
                    timelock,
                    GAS_LIMIT,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
    }

    function testEncodeTicketFunding() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](2);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        uint256 l2CallValue = FIRST_VALUE + SECOND_VALUE;

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    l2CallValue,
                    MAX_SUBMISSION_COST,
                    timelock,
                    timelock,
                    GAS_LIMIT,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
        assertEq(bridgeCalls[0].value, l2CallValue + GAS_VALUE);
        assertEq(bridgeCalls[0].value - l2CallValue, GAS_VALUE);
        assertEq(
            bridgeCalls[0].value, l2CallValue + MAX_SUBMISSION_COST + (GAS_LIMIT * MAX_FEE_PER_GAS)
        );
    }

    function testEncodeReceiverHubZero() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeBridgeNotSet() public {
        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.inboxes(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeNotSetOtherChain() public {
        vm.prank(admin);
        encoder.setInbox(OTHER_CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeUnset() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, address(0x00));

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeCheckOrder() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.inboxes(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeEmptyCalls() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, GAS_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    0,
                    MAX_SUBMISSION_COST,
                    timelock,
                    timelock,
                    GAS_LIMIT,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
    }

    function testEncodeGasParametersNotSet() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: FIRST_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    THIRD_VALUE,
                    0,
                    timelock,
                    timelock,
                    0,
                    0,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
    }

    function testEncodeMultipleCalls() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(GAS_LIMIT, MAX_FEE_PER_GAS, MAX_SUBMISSION_COST);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: THIRD_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        uint256 l2CallValue = FIRST_VALUE + SECOND_VALUE + THIRD_VALUE;

        assertEq(bridgeCalls[0].value, l2CallValue + GAS_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IInbox.createRetryableTicket,
                (
                    receiverHub,
                    l2CallValue,
                    MAX_SUBMISSION_COST,
                    timelock,
                    timelock,
                    GAS_LIMIT,
                    MAX_FEE_PER_GAS,
                    abi.encodeCall(IArbitrumCalls.arbitrumCall, (action.calls))
                )
            )
        );
    }

    function testEncodeNonZeroCallValueAllowed() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: FIRST_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, THIRD_VALUE);
    }

    function testEncodeCallValueOverflow() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](2);
        action.calls[0] = Call({target: callTargetA, value: type(uint256).max, data: ""});
        action.calls[1] = Call({target: callTargetB, value: 1, data: ""});

        vm.expectRevert(stdError.arithmeticError);
        encoder.encode(receiverHub, action);
    }

    function testEncodeGasCostOverflow() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(type(uint256).max, 2, 0);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(stdError.arithmeticError);
        encoder.encode(receiverHub, action);
    }

    function testEncodeTotalValueOverflow() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setGasParameters(0, 0, type(uint256).max);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 1, data: ""});

        vm.expectRevert(stdError.arithmeticError);
        encoder.encode(receiverHub, action);
    }

    function testEncodeAnyCaller() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, inbox);
    }

    function testEncodeChainIdMismatch() public {
        vm.prank(admin);
        encoder.setInbox(CHAIN_ID, inbox);

        vm.prank(admin);
        encoder.setInbox(OTHER_CHAIN_ID, otherInbox);

        MultichainAction memory action;
        action.chainId = OTHER_CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, otherInbox);
    }
}
