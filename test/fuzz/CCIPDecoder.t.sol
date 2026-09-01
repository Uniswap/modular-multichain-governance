// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {CCIPDecoder} from "src/modules/ccip/CCIPDecoder.sol";
import {CCIPError} from "src/modules/ccip/CCIPError.sol";
import {
    Any2EVMMessage,
    IAny2EVMMessageReceiver
} from "src/modules/ccip/IAny2EVMMessageReceiver.sol";
import {EVMTokenAmount} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";

contract CCIPDecoderFuzzTest is Test {
    address internal senderHub = vm.addr(100);
    address internal router = vm.addr(101);
    address internal fixedReceiverHub = vm.addr(102);
    uint64 internal constant L1_CHAIN_SELECTOR = 5009297550715157269;

    function testFuzzDecode(
        address caller,
        address receiverHub,
        bool callerIsRouter,
        uint64 sourceChainSelector,
        bool selectorIsL1,
        address sender,
        bool senderIsSenderHub,
        bytes32 messageId,
        uint256 callCount
    ) public {
        vm.assume(receiverHub != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);

        if (callerIsRouter) caller = router;
        else if (caller == router) caller = address(uint160(caller) ^ 1);

        if (selectorIsL1) sourceChainSelector = L1_CHAIN_SELECTOR;
        else if (sourceChainSelector == L1_CHAIN_SELECTOR) sourceChainSelector ^= 1;

        if (senderIsSenderHub) sender = senderHub;
        else if (sender == senderHub) sender = address(uint160(sender) ^ 1);

        CCIPDecoder decoder = new CCIPDecoder(senderHub, receiverHub, router);

        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bytes memory payload = abi.encodeCall(
            IAny2EVMMessageReceiver.ccipReceive,
            (Any2EVMMessage({
                    messageId: messageId,
                    sourceChainSelector: sourceChainSelector,
                    sender: abi.encode(sender),
                    data: abi.encode(calls),
                    destTokenAmounts: new EVMTokenAmount[](0)
                }))
        );

        address notReceiverHub = address(uint160(receiverHub) ^ 1);
        vm.assume(notReceiverHub != VM_ADDRESS);

        vm.prank(notReceiverHub);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(caller, payload);

        if (caller != router) {
            vm.prank(receiverHub);
            vm.expectRevert(CCIPError.ReceiverHubCallerNotRouter.selector);
            decoder.decode(caller, payload);
        } else if (sourceChainSelector != L1_CHAIN_SELECTOR) {
            vm.prank(receiverHub);
            vm.expectRevert(CCIPError.InvalidSourceChain.selector);
            decoder.decode(caller, payload);
        } else if (sender != senderHub) {
            vm.prank(receiverHub);
            vm.expectRevert(IDecoder.NotFromSenderHub.selector);
            decoder.decode(caller, payload);
        } else {
            vm.prank(receiverHub);
            Call[] memory decoded = decoder.decode(caller, payload);

            assertEq(decoded.length, callCount);
            for (uint256 i; i < callCount; i++) {
                assertEq(decoded[i].target, calls[i].target);
                assertEq(decoded[i].value, calls[i].value);
                assertEq(decoded[i].data, calls[i].data);
            }
        }
    }

    function testFuzzDecodeShortCalldata(bytes calldata data) public {
        uint256 length = bound(data.length, 0, 3);

        bytes memory short = new bytes(length);
        for (uint256 i; i < length; i++) {
            short[i] = data[i];
        }

        address receiverHub = fixedReceiverHub;
        CCIPDecoder decoder = new CCIPDecoder(senderHub, receiverHub, router);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(router, short);
    }
}
