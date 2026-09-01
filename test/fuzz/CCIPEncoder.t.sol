// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {CCIPEncoder} from "src/modules/ccip/CCIPEncoder.sol";
import {EVM2AnyMessage, EVMTokenAmount, IRouterClient} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";

contract CCIPEncoderFuzzTest is Test {
    address internal admin = vm.addr(101);
    address internal fixedReceiverHub = vm.addr(100);

    bytes4 internal constant GENERIC_EXTRA_ARGS_V2 = 0x181dcf10;
    uint256 internal constant ESTIMATED_GAS = 2_000_000;
    uint256 internal constant CHAIN_ID = 8453;
    uint64 internal constant CCIP_SELECTOR = 15971525489660198786;

    function testFuzzSetCcipChainSelector(
        address owner,
        address caller,
        bool callerIsOwner,
        uint256 chainId,
        uint64 ccipChainSelector
    ) public {
        if (callerIsOwner) caller = owner;
        else if (caller == owner) caller = address(uint160(caller) ^ 1);

        vm.assume(owner != VM_ADDRESS && caller != VM_ADDRESS);

        MockRouter router = new MockRouter();

        vm.prank(owner);
        CCIPEncoder encoder = new CCIPEncoder(address(router));

        if (caller == owner) {
            vm.expectEmit(address(encoder));
            emit CCIPEncoder.SetCcipChainSelector(chainId, ccipChainSelector);

            vm.prank(caller);
            encoder.setCcipChainSelector(chainId, ccipChainSelector);

            assertEq(encoder.ccipChainSelectors(chainId), ccipChainSelector);
        } else {
            vm.prank(caller);
            vm.expectRevert("UNAUTHORIZED");
            encoder.setCcipChainSelector(chainId, ccipChainSelector);

            assertEq(encoder.ccipChainSelectors(chainId), 0);
        }
    }

    function testFuzzEncode(
        address receiverHub,
        uint256 chainId,
        uint64 ccipChainSelector,
        uint256 fee,
        uint256 callCount
    ) public {
        if (receiverHub == address(0x00)) receiverHub = fixedReceiverHub;

        fee = bound(fee, 0, 100 ether);
        callCount = bound(callCount, 0, 8);

        MockRouter router = new MockRouter();
        router.setFee(fee);

        vm.prank(admin);
        CCIPEncoder encoder = new CCIPEncoder(address(router));

        vm.prank(admin);
        encoder.setCcipChainSelector(chainId, ccipChainSelector);

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: 0, data: abi.encode(i)});
        }

        Call[] memory bridgeCalls = encoder.encode(receiverHub, action);

        EVM2AnyMessage memory expected = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(action.calls),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2, uint256(2_000_000), false)
        });

        assertEq(bridgeCalls.length, 1);
        assertEq(bridgeCalls[0].target, address(router));
        assertEq(bridgeCalls[0].value, fee);
        assertEq(
            bridgeCalls[0].data,
            abi.encodeCall(IRouterClient.ccipSend, (ccipChainSelector, expected))
        );
    }

    function testFuzzEncodeInvalidCallValue(uint256 callCount, uint256 badIndex, uint256 badValue)
        public
    {
        callCount = bound(callCount, 1, 8);
        badIndex = bound(badIndex, 0, callCount - 1);
        badValue = bound(badValue, 1, type(uint256).max);

        MockRouter router = new MockRouter();
        vm.prank(admin);
        CCIPEncoder encoder = new CCIPEncoder(address(router));

        vm.prank(admin);
        encoder.setCcipChainSelector(CHAIN_ID, CCIP_SELECTOR);

        MultichainAction memory action;
        action.chainId = CHAIN_ID;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({
                target: vm.addr(i + 1), value: i == badIndex ? badValue : 0, data: abi.encode(i)
            });
        }

        vm.expectRevert(IEncoder.InvalidCallValue.selector);
        encoder.encode(fixedReceiverHub, action);
    }

    function testFuzzEncodeReceiverHubZero(uint256 chainId, uint256 callCount) public {
        callCount = bound(callCount, 0, 8);

        MockRouter router = new MockRouter();
        vm.prank(admin);
        CCIPEncoder encoder = new CCIPEncoder(address(router));

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        vm.expectRevert(IEncoder.InvalidReceiverHub.selector);
        encoder.encode(address(0x00), action);
    }

    function testFuzzEstimateGas(uint256 chainId, uint256 callCount, uint256[8] calldata callValues)
        public
    {
        callCount = bound(callCount, 0, 8);

        MockRouter router = new MockRouter();
        vm.prank(admin);
        CCIPEncoder encoder = new CCIPEncoder(address(router));

        MultichainAction memory action;
        action.chainId = chainId;
        action.calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            action.calls[i] =
                Call({target: vm.addr(i + 1), value: callValues[i], data: abi.encode(i)});
        }

        assertEq(encoder.estimateGas(action), 2_000_000);
    }
}
