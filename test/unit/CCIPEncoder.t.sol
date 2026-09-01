// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {CCIPEncoder} from "src/modules/ccip/CCIPEncoder.sol";
import {EVM2AnyMessage, EVMTokenAmount, IRouterClient} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";

contract CCIPEncoderTest is Test {
    error RouterUnreachable();

    CCIPEncoder internal encoder;
    MockRouter internal router;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal receiverHub = vm.addr(3);
    address internal routerEoa = vm.addr(4);
    address internal callTargetA = vm.addr(5);
    address internal callTargetB = vm.addr(6);
    address internal callTargetC = vm.addr(7);

    uint256 internal constant CHAIN_ID = 8453;

    uint64 internal constant CCIP_SELECTOR = 15971525489660198786;
    uint64 internal constant OTHER_CCIP_SELECTOR = 1234;

    bytes4 internal constant GENERIC_EXTRA_ARGS_V2 = 0x181dcf10;
    uint256 internal constant ESTIMATED_GAS = 2_000_000;
    bool internal constant ALLOW_OUT_OF_ORDER_EXEC = false;

    uint256 internal constant FEE = 0.05 ether;
    uint256 internal constant CALL_VALUE = 1 ether;

    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"0202";
    bytes internal constant THIRD_DATA = hex"03";
    bytes internal constant CALL_DATA = hex"dead";

    function setUp() public {
        router = new MockRouter();

        vm.prank(admin);
        encoder = new CCIPEncoder(address(router));
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        CCIPEncoder fresh = new CCIPEncoder(address(router));

        assertEq(fresh.ROUTER(), address(router));
        assertEq(fresh.owner(), admin);
        assertEq(fresh.ccipChainSelectors(CHAIN_ID), 0);
    }

    function testSetCcipChainSelector() public {
        vm.expectEmit(address(encoder));
        emit CCIPEncoder.SetCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        assertEq(encoder.ccipChainSelectors(CHAIN_ID), CCIP_SELECTOR);
    }

    function testSetCcipChainSelectorOverwrite() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        vm.expectEmit(address(encoder));
        emit CCIPEncoder.SetCcipChainSelector(CHAIN_ID, OTHER_CCIP_SELECTOR);

        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, OTHER_CCIP_SELECTOR);

        assertEq(encoder.ccipChainSelectors(CHAIN_ID), OTHER_CCIP_SELECTOR);
    }

    function testSetCcipChainSelectorZero() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        vm.expectEmit(address(encoder));
        emit CCIPEncoder.SetCcipChainSelector(CHAIN_ID, 0);

        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, 0);

        assertEq(encoder.ccipChainSelectors(CHAIN_ID), 0);
    }

    function testSetCcipChainSelectorNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        assertEq(encoder.ccipChainSelectors(CHAIN_ID), 0);
    }

    function testEncode() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFee(FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 0, data: CALL_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        EVM2AnyMessage memory expected = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(action.calls),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2, ESTIMATED_GAS, ALLOW_OUT_OF_ORDER_EXEC
            )
        });

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, address(router));
        assertEq(bridgeCalls[0].value, FEE);
        assertEq(
            bridgeCalls[0].data, abi.encodeCall(IRouterClient.ccipSend, (CCIP_SELECTOR, expected))
        );
    }

    function testEncodeReceiverHubZero() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeInvalidCallValue() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: 1, data: CALL_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueLastCall() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: CALL_VALUE, data: THIRD_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeInvalidCallValueMiddleCall() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: CALL_VALUE, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: THIRD_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeAllZeroCallValues() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFee(FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: THIRD_DATA});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, FEE);
    }

    function testEncodeCheckOrder() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](1);
        action.calls[0] = Call({target: callTargetA, value: CALL_VALUE, data: CALL_DATA});

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testEncodeCheckOrderBeforeGetFee() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFeeRevert(true, abi.encodeWithSelector(RouterUnreachable.selector));

        MultichainAction memory zeroReceiverHub;
        zeroReceiverHub.chainId = CHAIN_ID;
        zeroReceiverHub.calls = new Call[](0);

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), zeroReceiverHub);

        MultichainAction memory valueBearing;
        valueBearing.chainId = CHAIN_ID;
        valueBearing.calls = new Call[](1);
        valueBearing.calls[0] = Call({target: callTargetA, value: 1, data: CALL_DATA});

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(receiverHub, valueBearing);
    }

    function testEncodeChainSelectorNotSet() public {
        router.setFee(FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        EVM2AnyMessage memory expected = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(action.calls),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2, ESTIMATED_GAS, ALLOW_OUT_OF_ORDER_EXEC
            )
        });

        assertEq(encoder.ccipChainSelectors(CHAIN_ID), 0);
        assertEq(bridgeCalls[0].data, abi.encodeCall(IRouterClient.ccipSend, (uint64(0), expected)));
    }

    function testEncodeEmptyCalls() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFee(FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        EVM2AnyMessage memory expected = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(new Call[](0)),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2, ESTIMATED_GAS, ALLOW_OUT_OF_ORDER_EXEC
            )
        });

        assertEq(
            bridgeCalls[0].data, abi.encodeCall(IRouterClient.ccipSend, (CCIP_SELECTOR, expected))
        );
    }

    function testEncodeMultipleCalls() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFee(FEE);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](3);
        action.calls[0] = Call({target: callTargetA, value: 0, data: FIRST_DATA});
        action.calls[1] = Call({target: callTargetB, value: 0, data: SECOND_DATA});
        action.calls[2] = Call({target: callTargetC, value: 0, data: ""});

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        EVM2AnyMessage memory expected = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(action.calls),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2, ESTIMATED_GAS, ALLOW_OUT_OF_ORDER_EXEC
            )
        });

        assertEq(
            bridgeCalls[0].data, abi.encodeCall(IRouterClient.ccipSend, (CCIP_SELECTOR, expected))
        );
    }

    function testEncodeZeroFee() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFee(0);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].value, 0);
    }

    function testEncodeRouterReverts() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        router.setFeeRevert(true, abi.encodeWithSelector(RouterUnreachable.selector));

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.expectRevert(RouterUnreachable.selector);
        encoder.encode(receiverHub, action);
    }

    function testEncodeRouterNotAContract() public {
        vm.prank(admin);
        CCIPEncoder eoaRouterEncoder = new CCIPEncoder(routerEoa);

        vm.prank(admin);
        eoaRouterEncoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(routerEoa.code.length, 0);

        (bool success, bytes memory returnData) = address(eoaRouterEncoder)
            .call(abi.encodeCall(CCIPEncoder.encode, (receiverHub, action)));

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testEncodeAnyCaller() public {
        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        vm.prank(bob);
        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        assertEq(bridgeCalls[0].target, address(router));
    }

    function testEstimateGas() public view {
        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](0);

        assertEq(encoder.estimateGas(action), ESTIMATED_GAS);
    }
}
