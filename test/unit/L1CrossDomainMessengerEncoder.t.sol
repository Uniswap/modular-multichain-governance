// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Test, stdError} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ICrossDomainMessenger} from "src/interfaces/bridges/ICrossDomainMessenger.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {
    ICrossDomainMessengerCalls
} from "src/modules/optimism-messenger/ICrossDomainMessengerCalls.sol";
import {
    L1CrossDomainMessengerEncoder
} from "src/modules/optimism-messenger/L1CrossDomainMessengerEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract L1CrossDomainMessengerEncoderTest is Test {
    L1CrossDomainMessengerEncoder internal encoder;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal messenger = vm.addr(4);
    address internal otherMessenger = vm.addr(5);
    address internal callTargetA = vm.addr(6);
    address internal callTargetB = vm.addr(7);
    address internal callTargetC = vm.addr(8);

    uint256 internal constant CHAIN_ID = 10;
    uint256 internal constant OTHER_CHAIN_ID = 8453;

    uint32 internal constant MIN_GAS_LIMIT = 1_000_000;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        vm.prank(admin);
        encoder = new L1CrossDomainMessengerEncoder();
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        L1CrossDomainMessengerEncoder fresh = new L1CrossDomainMessengerEncoder();

        assertEq(fresh.owner(), admin);
        assertEq(fresh.minGasLimit(), 0);
        assertEq(fresh.messengers(CHAIN_ID), address(0x00));
    }

    function testSetMinGasLimit() public {
        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMinGasLimit(MIN_GAS_LIMIT);

        vm.prank(admin);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        assertEq(encoder.minGasLimit(), MIN_GAS_LIMIT);
    }

    function testSetMinGasLimitZero() public {
        vm.prank(admin);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMinGasLimit(0);

        vm.prank(admin);
        encoder.setMinGasLimit(0);

        assertEq(encoder.minGasLimit(), 0);
    }

    function testSetMinGasLimitMax() public {
        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMinGasLimit(type(uint32).max);

        vm.prank(admin);
        encoder.setMinGasLimit(type(uint32).max);

        assertEq(encoder.minGasLimit(), type(uint32).max);
    }

    function testSetMinGasLimitNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        assertEq(encoder.minGasLimit(), 0);
    }

    function testSetMessenger() public {
        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        assertEq(encoder.messengers(CHAIN_ID), messenger);
    }

    function testSetMessengerOverwrite() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMessenger(CHAIN_ID, otherMessenger);

        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, otherMessenger);

        assertEq(encoder.messengers(CHAIN_ID), otherMessenger);
    }

    function testSetMessengerZeroAddress() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.expectEmit(address(encoder));
        emit L1CrossDomainMessengerEncoder.SetMessenger(CHAIN_ID, address(0x00));

        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, address(0x00));

        assertEq(encoder.messengers(CHAIN_ID), address(0x00));
    }

    function testSetMessengerNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setMessenger(CHAIN_ID, messenger);

        assertEq(encoder.messengers(CHAIN_ID), address(0x00));
    }

    function testEncode() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, messenger);
        assertEq(bridgeCalls[0].value, THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall, (action.calls)
                    ),
                    MIN_GAS_LIMIT
                )
            )
        );
    }

    function testEncodeReceiverHubZero() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeBridgeNotSet() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.messengers(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeNotSetOtherChain() public {
        vm.prank(admin);
        encoder.setMessenger(OTHER_CHAIN_ID, messenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeUnset() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, address(0x00));

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

        assertEq(encoder.messengers(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodePerChainMessenger() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMessenger(OTHER_CHAIN_ID, otherMessenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        MultichainAction memory otherAction;
        otherAction.chainId = OTHER_CHAIN_ID;
        otherAction.calls = new Call[](0);

        assertEq(encoder.encode(receiverHub, action)[0].target, messenger);
        assertEq(encoder.encode(receiverHub, otherAction)[0].target, otherMessenger);
    }

    function testEncodeEmptyCalls() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall, (action.calls)
                    ),
                    MIN_GAS_LIMIT
                )
            )
        );
    }

    function testEncodeNoGasSurcharge() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMinGasLimit(type(uint32).max);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: SECOND_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, SECOND_VALUE);
    }

    function testEncodeMinGasLimitNotSet() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(encoder.minGasLimit(), 0);
        assertEq(bridgeCalls[0].value, THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall, (action.calls)
                    ),
                    0
                )
            )
        );
    }

    function testEncodeMultipleCalls() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        vm.prank(admin);
        encoder.setMinGasLimit(MIN_GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: THIRD_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, FIRST_VALUE + SECOND_VALUE + THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    receiverHub,
                    abi.encodeCall(
                        ICrossDomainMessengerCalls.crossDomainMessengerCall, (action.calls)
                    ),
                    MIN_GAS_LIMIT
                )
            )
        );
    }

    function testEncodeCallValueOverflow() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](2);
        action.calls[0] = Call({target: callTargetA, value: type(uint256).max, data: ""});
        action.calls[1] = Call({target: callTargetB, value: 1, data: ""});

        vm.expectRevert(stdError.arithmeticError);
        encoder.encode(receiverHub, action);
    }

    function testEncodeAnyCaller() public {
        vm.prank(admin);
        encoder.setMessenger(CHAIN_ID, messenger);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, messenger);
    }
}
