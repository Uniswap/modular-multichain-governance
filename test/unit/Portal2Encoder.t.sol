// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test, stdError} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IPortal2Calls} from "src/modules/optimism-portal2/IPortal2Calls.sol";
import {Portal2Encoder} from "src/modules/optimism-portal2/Portal2Encoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract Portal2EncoderTest is Test {
    Portal2Encoder internal encoder;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal portal = vm.addr(4);
    address internal otherPortal = vm.addr(5);
    address internal callTargetA = vm.addr(6);
    address internal callTargetB = vm.addr(7);
    address internal callTargetC = vm.addr(8);

    uint256 internal constant CHAIN_ID = 10;
    uint256 internal constant OTHER_CHAIN_ID = 8453;

    uint64 internal constant GAS_LIMIT = 1_000_000;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"030303";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        vm.prank(admin);
        encoder = new Portal2Encoder();
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        Portal2Encoder fresh = new Portal2Encoder();

        assertEq(fresh.owner(), admin);
        assertEq(fresh.gasLimit(), 0);
        assertEq(fresh.portals(CHAIN_ID), address(0x00));
    }

    function testSetGasLimit() public {
        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetGasLimit(GAS_LIMIT);

        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        assertEq(encoder.gasLimit(), GAS_LIMIT);
    }

    function testSetGasLimitZero() public {
        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetGasLimit(0);

        vm.prank(admin);
        encoder.setGasLimit(0);

        assertEq(encoder.gasLimit(), 0);
    }

    function testSetGasLimitMax() public {
        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetGasLimit(type(uint64).max);

        vm.prank(admin);
        encoder.setGasLimit(type(uint64).max);

        assertEq(encoder.gasLimit(), type(uint64).max);
    }

    function testSetGasLimitNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setGasLimit(GAS_LIMIT);

        assertEq(encoder.gasLimit(), 0);
    }

    function testSetPortal() public {
        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        assertEq(encoder.portals(CHAIN_ID), portal);
    }

    function testSetPortalOverwrite() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetPortal(CHAIN_ID, otherPortal);

        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, otherPortal);

        assertEq(encoder.portals(CHAIN_ID), otherPortal);
    }

    function testSetPortalZeroAddress() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.expectEmit(address(encoder));
        emit Portal2Encoder.SetPortal(CHAIN_ID, address(0x00));

        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, address(0x00));

        assertEq(encoder.portals(CHAIN_ID), address(0x00));
    }

    function testSetPortalNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setPortal(CHAIN_ID, portal);

        assertEq(encoder.portals(CHAIN_ID), address(0x00));
    }

    function testEncode() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, portal);
        assertEq(bridgeCalls[0].value, THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    THIRD_VALUE,
                    GAS_LIMIT,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testEncodeReceiverHubZero() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

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

        assertEq(encoder.portals(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeNotSetOtherChain() public {
        vm.prank(admin);
        encoder.setPortal(OTHER_CHAIN_ID, portal);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.BridgeNotSet.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeBridgeUnset() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, address(0x00));

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

        assertEq(encoder.portals(CHAIN_ID), address(0x00));

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeEmptyCalls() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    0,
                    GAS_LIMIT,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testEncodeNonZeroCallValueAllowed() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: THIRD_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, THIRD_VALUE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    THIRD_VALUE,
                    0,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testEncodeNoGasSurcharge() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setGasLimit(type(uint64).max);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: SECOND_VALUE, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, SECOND_VALUE);
    }

    function testEncodeGasLimitNotSet() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(encoder.gasLimit(), 0);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    0,
                    0,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testEncodeIsCreationAlwaysFalse() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    0,
                    GAS_LIMIT,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
        assertTrue(
            keccak256(bridgeCalls[0].data)
                != keccak256(
                    abi.encodeCall(
                        IPortal2.depositTransaction,
                        (
                            receiverHub,
                            0,
                            GAS_LIMIT,
                            true,
                            abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                        )
                    )
                )
        );
    }

    function testEncodeMultipleCalls() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

        vm.prank(admin);
        encoder.setGasLimit(GAS_LIMIT);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: THIRD_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        uint256 totalValue = FIRST_VALUE + SECOND_VALUE + THIRD_VALUE;

        assertEq(bridgeCalls[0].value, totalValue);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    totalValue,
                    GAS_LIMIT,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (action.calls))
                )
            )
        );
    }

    function testEncodeCallValueOverflow() public {
        vm.prank(admin);
        encoder.setPortal(CHAIN_ID, portal);

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
        encoder.setPortal(CHAIN_ID, portal);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, portal);
    }
}
