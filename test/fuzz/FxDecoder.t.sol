// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IFxMessageProcessor} from "src/interfaces/bridges/IFxMessageProcessor.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {FxDecoder} from "src/modules/fx/FxDecoder.sol";
import {Call} from "src/types/Call.sol";

contract FxDecoderFuzzTest is Test {
    address internal senderHub = vm.addr(100);
    address internal fxChild = vm.addr(101);
    address internal fixedReceiverHub = vm.addr(102);

    function testFuzzDecode(
        address caller,
        address receiverHub,
        bool callerIsFxChild,
        address rootSender,
        bool senderIsSenderHub,
        uint256 stateId,
        uint256 callCount
    ) public {
        vm.assume(receiverHub != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);

        if (callerIsFxChild) caller = fxChild;
        else if (caller == fxChild) caller = address(uint160(caller) ^ 1);

        if (senderIsSenderHub) rootSender = senderHub;
        else if (rootSender == senderHub) rootSender = address(uint160(rootSender) ^ 1);

        FxDecoder decoder = new FxDecoder(senderHub, receiverHub, fxChild);

        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bytes memory payload = abi.encodeCall(
            IFxMessageProcessor.processMessageFromRoot, (stateId, rootSender, abi.encode(calls))
        );

        address notReceiverHub = address(uint160(receiverHub) ^ 1);
        vm.assume(notReceiverHub != VM_ADDRESS);

        vm.prank(notReceiverHub);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(caller, payload);

        if (caller != fxChild) {
            vm.prank(receiverHub);
            vm.expectRevert(IDecoder.InvalidReceiverHubCaller.selector);
            decoder.decode(caller, payload);
        } else if (rootSender != senderHub) {
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
        FxDecoder decoder = new FxDecoder(senderHub, receiverHub, fxChild);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(fxChild, short);
    }
}
