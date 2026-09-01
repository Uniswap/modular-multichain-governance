// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IWormholeCalls} from "src/modules/wormhole/IWormholeCalls.sol";
import {WormholeEncoder} from "src/modules/wormhole/WormholeEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockWormhole} from "test/mocks/MockWormhole.sol";

contract WormholeEncoderTest is Test {
    WormholeEncoder internal encoder;
    MockWormhole internal wormhole;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal senderHub = vm.addr(3);
    address internal receiverHub = vm.addr(4);
    address internal otherReceiverHub = vm.addr(5);
    address internal wormholeEoa = vm.addr(6);
    address internal callTargetA = vm.addr(7);
    address internal callTargetB = vm.addr(8);
    address internal callTargetC = vm.addr(9);

    uint256 internal constant CHAIN_ID = 8453;
    uint256 internal constant OTHER_CHAIN_ID = 42161;
    uint256 internal constant LARGE_CHAIN_ID = 81457;

    uint32 internal constant WORMHOLE_NONCE_FIELD = 0;
    uint8 internal constant CONSISTENCY_LEVEL = 1;

    uint32 internal constant START_NONCE = 7;
    uint32 internal constant REWOUND_NONCE = 1;

    uint256 internal constant MESSAGE_FEE = 0.01 ether;

    uint256 internal constant FIRST_VALUE = 1 ether;
    uint256 internal constant SECOND_VALUE = 2 ether;
    uint256 internal constant THIRD_VALUE = 3 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        wormhole = new MockWormhole();

        vm.prank(admin);
        encoder = new WormholeEncoder(address(wormhole), senderHub);
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        WormholeEncoder fresh = new WormholeEncoder(address(wormhole), senderHub);

        assertEq(fresh.WORMHOLE(), address(wormhole));
        assertEq(fresh.SENDER_HUB(), senderHub);
        assertEq(fresh.owner(), admin);
        assertEq(fresh.CONSISTENCY_LEVEL(), CONSISTENCY_LEVEL);
        assertEq(fresh.nonces(CHAIN_ID), 0);
        assertEq(fresh.nonces(0), 0);
    }

    function testEmergencySetNonce() public {
        vm.expectEmit(address(encoder));
        emit WormholeEncoder.EmergencySetNonce(CHAIN_ID, START_NONCE);

        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, START_NONCE);

        assertEq(encoder.nonces(CHAIN_ID), START_NONCE);
    }

    function testEmergencySetNonceZero() public {
        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, START_NONCE);

        vm.expectEmit(address(encoder));
        emit WormholeEncoder.EmergencySetNonce(CHAIN_ID, 0);

        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, 0);

        assertEq(encoder.nonces(CHAIN_ID), 0);
    }

    function testEmergencySetNonceMax() public {
        vm.expectEmit(address(encoder));
        emit WormholeEncoder.EmergencySetNonce(CHAIN_ID, type(uint32).max);

        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, type(uint32).max);

        assertEq(encoder.nonces(CHAIN_ID), type(uint32).max);
    }

    function testEmergencySetNonceNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.emergencySetNonce(CHAIN_ID, START_NONCE);

        assertEq(encoder.nonces(CHAIN_ID), 0);
    }

    function testEmergencySetNonceRewindsPayloadNonce() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        assertEq(encoder.nonces(CHAIN_ID), 2);

        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, REWOUND_NONCE);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(REWOUND_NONCE), CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(encoder.nonces(CHAIN_ID), uint256(REWOUND_NONCE) + 1);
    }

    function testEncode() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, address(wormhole));
        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(0), CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeCallerNotSenderHub() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        vm.expectRevert(IEncoder.NotSenderHub.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.nonces(CHAIN_ID), 0);
    }

    function testEncodeCallerNotSenderHubOwner() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.owner(), admin);

        vm.prank(admin);
        vm.expectRevert(IEncoder.NotSenderHub.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.nonces(CHAIN_ID), 0);
    }

    function testEncodeWormholeNonceFieldZero() public {
        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, START_NONCE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(START_NONCE), CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeNonceInPayload() public {
        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, START_NONCE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(START_NONCE), CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(encoder.nonces(CHAIN_ID), uint256(START_NONCE) + 1);
    }

    function testEncodeIncrementsNonce() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.nonces(CHAIN_ID), 0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, action);

        assertEq(encoder.nonces(CHAIN_ID), 1);
    }

    function testEncodeNoncePerChainIndependent() public {
        MultichainAction memory actionA;
        actionA.chainId = CHAIN_ID;
        actionA.calls = new Call[](0);

        MultichainAction memory actionB;
        actionB.chainId = OTHER_CHAIN_ID;
        actionB.calls = new Call[](0);

        vm.prank(senderHub);
        encoder.encode(receiverHub, actionA);

        vm.prank(senderHub);
        encoder.encode(receiverHub, actionA);

        assertEq(encoder.nonces(CHAIN_ID), 2);
        assertEq(encoder.nonces(OTHER_CHAIN_ID), 0);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, actionB);

        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(0), OTHER_CHAIN_ID, actionB.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
        assertEq(encoder.nonces(OTHER_CHAIN_ID), 1);
    }

    function testEncodeEmptyCalls() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
    }

    function testEncodeMultipleCalls() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(0), CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeLargeChainId() public {
        MultichainAction memory action;
        action.chainId = LARGE_CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertTrue(action.chainId > type(uint16).max);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    WORMHOLE_NONCE_FIELD,
                    abi.encodeCall(
                        IWormholeCalls.wormholeCall,
                        (abi.encode(uint256(0), LARGE_CHAIN_ID, action.calls))
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }

    function testEncodeZeroMessageFee() public {
        wormhole.setMessageFee(0);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
    }

    function testEncodeReceiverHubIgnored() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        vm.prank(senderHub);
        Call[] memory withZero = encoder.encode(address(0x00), action);

        vm.prank(admin);
        encoder.emergencySetNonce(CHAIN_ID, 0);

        vm.prank(senderHub);
        Call[] memory withAddress = encoder.encode(otherReceiverHub, action);

        assertEq(withZero[0].target, withAddress[0].target);
        assertEq(withZero[0].value, withAddress[0].value);
        assertEq(withZero[0].data, withAddress[0].data);
    }

    function testEncodeInvalidCallValue() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueLastCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: THIRD_VALUE, data: ""});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueMiddleCall() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: SECOND_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueDoesNotIncrementNonce() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(senderHub);
        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);

        assertEq(encoder.nonces(CHAIN_ID), 0);
    }

    function testEncodeAllZeroCallValues() public {
        wormhole.setMessageFee(MESSAGE_FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        vm.prank(senderHub);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, MESSAGE_FEE);
        assertEq(encoder.nonces(CHAIN_ID), 1);
    }

    function testEncodeCheckOrderCallerBeforeCallValue() public {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: FIRST_VALUE, data: CALL_DATA});

        vm.prank(bob);
        vm.expectRevert(IEncoder.NotSenderHub.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeWormholeNotAContract() public {
        vm.prank(admin);
        WormholeEncoder eoaWormholeEncoder = new WormholeEncoder(wormholeEoa, senderHub);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(wormholeEoa.code.length, 0);

        vm.prank(senderHub);
        (bool success, bytes memory returnData) = address(eoaWormholeEncoder)
            .call(abi.encodeCall(WormholeEncoder.encode, (receiverHub, action)));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}
