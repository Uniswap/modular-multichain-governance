// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {IPortal2Calls} from "src/modules/optimism-portal2/IPortal2Calls.sol";
import {Portal2Decoder} from "src/modules/optimism-portal2/Portal2Decoder.sol";
import {Call} from "src/types/Call.sol";

contract Portal2DecoderFuzzTest is Test {
    uint160 internal constant OP_STACK_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    address internal senderHub = vm.addr(100);
    address internal fixedReceiverHub = vm.addr(101);

    function testFuzzDecode(
        address caller,
        address receiverHub,
        bool callerIsAliasedSenderHub,
        uint256 callCount
    ) public {
        vm.assume(receiverHub != VM_ADDRESS);

        callCount = bound(callCount, 0, 8);

        address aliasedSenderHub = address(uint160(senderHub) + OP_STACK_ALIAS);

        if (callerIsAliasedSenderHub) caller = aliasedSenderHub;
        else if (caller == aliasedSenderHub) caller = address(uint160(caller) ^ 1);

        Portal2Decoder decoder = new Portal2Decoder(senderHub, receiverHub);

        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = Call({target: vm.addr(i + 1), value: i, data: abi.encode(i)});
        }

        bytes memory payload = abi.encodeCall(IPortal2Calls.portal2Call, (calls));

        address notReceiverHub = address(uint160(receiverHub) ^ 1);
        vm.assume(notReceiverHub != VM_ADDRESS);

        vm.prank(notReceiverHub);
        vm.expectRevert(IDecoder.CallerNotReceiverHub.selector);
        decoder.decode(caller, payload);

        if (caller == aliasedSenderHub) {
            vm.prank(receiverHub);
            Call[] memory decoded = decoder.decode(caller, payload);

            assertEq(decoded.length, callCount);
            for (uint256 i; i < callCount; i++) {
                assertEq(decoded[i].target, calls[i].target);
                assertEq(decoded[i].value, calls[i].value);
                assertEq(decoded[i].data, calls[i].data);
            }
        } else {
            vm.prank(receiverHub);
            vm.expectRevert(IDecoder.NotFromSenderHub.selector);
            decoder.decode(caller, payload);
        }
    }

    function testFuzzDecodeShortCalldata(bytes calldata data) public {
        uint256 length = bound(data.length, 0, 3);

        bytes memory short = new bytes(length);
        for (uint256 i; i < length; i++) {
            short[i] = data[i];
        }

        address receiverHub = fixedReceiverHub;
        Portal2Decoder decoder = new Portal2Decoder(senderHub, receiverHub);

        vm.prank(receiverHub);
        vm.expectRevert(IDecoder.CalldataTooShort.selector);
        decoder.decode(address(uint160(senderHub) + OP_STACK_ALIAS), short);
    }

    function testFuzzRemoveAlias(address l2Address) public {
        Portal2Decoder decoder = new Portal2Decoder(senderHub, fixedReceiverHub);

        address expected;
        unchecked {
            expected = address(uint160(l2Address) - OP_STACK_ALIAS);
        }

        assertEq(decoder.removeAlias(l2Address), expected);
    }

    function testFuzzRemoveAliasRoundTrip(address l1Address) public {
        Portal2Decoder decoder = new Portal2Decoder(senderHub, fixedReceiverHub);

        address aliased;
        unchecked {
            aliased = address(uint160(l1Address) + OP_STACK_ALIAS);
        }

        assertEq(decoder.removeAlias(aliased), l1Address);
    }
}
