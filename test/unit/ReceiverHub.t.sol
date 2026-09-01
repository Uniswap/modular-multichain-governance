// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Test} from "lib/forge-std/src/Test.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ReceiverHub} from "src/ReceiverHub.sol";
import {IReceiverHub} from "src/interfaces/IReceiverHub.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";
import {MockDecoder} from "test/mocks/MockDecoder.sol";
import {MockTarget} from "test/mocks/MockTarget.sol";

contract ReceiverHubTest is Test {
    ReceiverHub internal receiverHub;
    MockDecoder internal decoder;
    MockTarget internal target;

    address internal admin = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal relayer = vm.addr(3);
    address internal otherDecoder = vm.addr(4);
    address internal decoderEoa = vm.addr(5);
    address internal eoaTarget = vm.addr(6);

    bytes4 internal constant DECODER_SELECTOR = 0x11223344;
    bytes4 internal constant OTHER_SELECTOR = 0xdeadbeef;
    bytes4 internal constant ZERO_SELECTOR = 0x00000000;
    bytes4 internal constant PADDED_SELECTOR = 0xab000000;
    bytes4 internal constant OWNER_SELECTOR = bytes4(keccak256("owner()"));
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant UNSUPPORTED_INTERFACE_ID = 0xffffffff;

    bytes internal constant DISPATCH_CALLDATA = hex"11223344";
    bytes internal constant DISPATCH_CALLDATA_WITH_SUFFIX = hex"1122334455";
    bytes internal constant SHORT_CALLDATA = hex"ab";
    bytes internal constant ZERO_CALLDATA = hex"00000000";

    bytes internal constant CALL_DATA = hex"c0ffee";
    bytes internal constant FIRST_DATA = hex"01";
    bytes internal constant SECOND_DATA = hex"02";
    bytes internal constant THIRD_DATA = hex"03";

    uint256 internal constant CALL_VALUE = 1 ether;
    uint256 internal constant FUNDING = 6 ether;

    function setUp() public {
        vm.prank(admin);
        receiverHub = new ReceiverHub();

        decoder = new MockDecoder();
        target = new MockTarget();
    }

    function testConstructor() public {
        vm.expectEmit();
        emit Owned.OwnershipTransferred(address(0x00), admin);

        vm.prank(admin);
        ReceiverHub fresh = new ReceiverHub();

        assertEq(fresh.owner(), admin);
    }

    function testSetDecoder() public {
        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetDecoder(DECODER_SELECTOR, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        assertEq(receiverHub.decoders(DECODER_SELECTOR), address(decoder));
    }

    function testSetDecoderOverwrite() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        MockDecoder second = new MockDecoder();

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetDecoder(DECODER_SELECTOR, address(second));

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(second));

        assertEq(receiverHub.decoders(DECODER_SELECTOR), address(second));
    }

    function testSetDecoderZeroAddress() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetDecoder(DECODER_SELECTOR, address(0x00));

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(0x00));

        assertEq(receiverHub.decoders(DECODER_SELECTOR), address(0x00));

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(IReceiverHub.NoDecoderForSelector.selector, DECODER_SELECTOR)
        );
    }

    function testSetDecoderZeroSelector() public {
        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetDecoder(ZERO_SELECTOR, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(ZERO_SELECTOR, address(decoder));

        assertEq(receiverHub.decoders(ZERO_SELECTOR), address(decoder));
    }

    function testSetDecoderNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        assertEq(receiverHub.decoders(DECODER_SELECTOR), address(0x00));
    }

    function testSetSupportsInterface() public {
        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetSupportsInterface(ERC165_INTERFACE_ID, true);

        vm.prank(admin);
        receiverHub.setSupportsInterface(ERC165_INTERFACE_ID, true);

        assertTrue(receiverHub.supportsInterface(ERC165_INTERFACE_ID));
    }

    function testSetSupportsInterfaceFalse() public {
        vm.prank(admin);
        receiverHub.setSupportsInterface(ERC165_INTERFACE_ID, true);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.SetSupportsInterface(ERC165_INTERFACE_ID, false);

        vm.prank(admin);
        receiverHub.setSupportsInterface(ERC165_INTERFACE_ID, false);

        assertFalse(receiverHub.supportsInterface(ERC165_INTERFACE_ID));
    }

    function testSetSupportsInterfaceNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        receiverHub.setSupportsInterface(ERC165_INTERFACE_ID, true);

        assertFalse(receiverHub.supportsInterface(ERC165_INTERFACE_ID));
    }

    function testSupportsInterfaceDefault() public view {
        assertFalse(receiverHub.supportsInterface(ERC165_INTERFACE_ID));
        assertFalse(receiverHub.supportsInterface(ZERO_SELECTOR));
        assertFalse(receiverHub.supportsInterface(0xffffffff));
    }

    function testFallback() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});
        decoder.setReturnCalls(calls);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, DECODER_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA_WITH_SUFFIX);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 1);
        assertEq(decoder.lastCaller(), relayer);
        assertEq(decoder.lastData(), DISPATCH_CALLDATA_WITH_SUFFIX);
        assertEq(target.callCount(), 1);
        assertEq(target.dataAt(0), CALL_DATA);
        assertEq(target.valueAt(0), 0);
    }

    function testFallbackDecoderNotSet() public {
        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(IReceiverHub.NoDecoderForSelector.selector, DECODER_SELECTOR)
        );
    }

    function testFallbackDecoderUnset() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(0x00));

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(IReceiverHub.NoDecoderForSelector.selector, DECODER_SELECTOR)
        );
    }

    function testFallbackAnyCaller() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        decoder.setReturnCalls(new Call[](0));

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(bob, DECODER_SELECTOR, address(decoder));

        vm.prank(bob);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 1);
        assertEq(decoder.lastCaller(), bob);
    }

    function testFallbackEmptyCalls() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        decoder.setReturnCalls(new Call[](0));

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, DECODER_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(target.callCount(), 0);
    }

    function testFallbackMultipleCalls() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});
        calls[1] = Call({target: address(target), value: 0, data: SECOND_DATA});
        calls[2] = Call({target: address(target), value: 0, data: THIRD_DATA});
        decoder.setReturnCalls(calls);

        vm.expectEmit(address(receiverHub), 1);
        emit IReceiverHub.CallsReceived(relayer, DECODER_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(target.callCount(), 3);
        assertEq(target.dataAt(0), FIRST_DATA);
        assertEq(target.dataAt(1), SECOND_DATA);
        assertEq(target.dataAt(2), THIRD_DATA);
    }

    function testFallbackForwardsValue() public {
        vm.deal(address(receiverHub), FUNDING);

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        MockTarget targetB = new MockTarget();
        MockTarget targetC = new MockTarget();

        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(target), value: CALL_VALUE, data: FIRST_DATA});
        calls[1] = Call({target: address(targetB), value: 2 * CALL_VALUE, data: SECOND_DATA});
        calls[2] = Call({target: address(targetC), value: 3 * CALL_VALUE, data: THIRD_DATA});
        decoder.setReturnCalls(calls);

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(address(target).balance, CALL_VALUE);
        assertEq(address(targetB).balance, 2 * CALL_VALUE);
        assertEq(address(targetC).balance, 3 * CALL_VALUE);
        assertEq(address(receiverHub).balance, 0);
        assertEq(target.valueAt(0), CALL_VALUE);
        assertEq(targetB.valueAt(0), 2 * CALL_VALUE);
        assertEq(targetC.valueAt(0), 3 * CALL_VALUE);
    }

    function testFallbackWithMsgValue() public {
        vm.deal(relayer, FUNDING);

        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: CALL_VALUE, data: FIRST_DATA});
        decoder.setReturnCalls(calls);

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call{value: CALL_VALUE}(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(address(target).balance, CALL_VALUE);
        assertEq(address(receiverHub).balance, 0);
    }

    function testFallbackShortCalldata() public {
        vm.prank(admin);
        receiverHub.setDecoder(PADDED_SELECTOR, address(decoder));

        decoder.setReturnCalls(new Call[](0));

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, PADDED_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(SHORT_CALLDATA);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 1);
        assertEq(decoder.lastData(), SHORT_CALLDATA);
    }

    function testFallbackZeroSelector() public {
        vm.prank(admin);
        receiverHub.setDecoder(ZERO_SELECTOR, address(decoder));

        decoder.setReturnCalls(new Call[](0));

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, ZERO_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(ZERO_CALLDATA);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 1);
        assertEq(decoder.lastData(), ZERO_CALLDATA);
    }

    function testFallbackShadowedSelector() public {
        vm.prank(admin);
        receiverHub.setDecoder(OWNER_SELECTOR, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(IReceiverHub.decoders.selector, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(IReceiverHub.supportsInterface.selector, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(IReceiverHub.setDecoder.selector, address(decoder));

        vm.prank(admin);
        receiverHub.setDecoder(IReceiverHub.setSupportsInterface.selector, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});
        decoder.setReturnCalls(calls);

        vm.recordLogs();

        assertEq(receiverHub.owner(), admin);
        assertEq(receiverHub.decoders(OWNER_SELECTOR), address(decoder));
        assertFalse(receiverHub.supportsInterface(ERC165_INTERFACE_ID));

        vm.prank(admin);
        receiverHub.setDecoder(OTHER_SELECTOR, otherDecoder);

        assertEq(receiverHub.decoders(OTHER_SELECTOR), otherDecoder);

        vm.prank(admin);
        receiverHub.setSupportsInterface(ERC165_INTERFACE_ID, true);

        assertTrue(receiverHub.supportsInterface(ERC165_INTERFACE_ID));

        assertEq(decoder.decodeCount(), 0);
        assertEq(target.callCount(), 0);
        assertEq(vm.getRecordedLogs().length, 2);
    }

    function testFallbackDecoderReverts() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        decoder.setRevert(true, abi.encodeWithSelector(IDecoder.InvalidSelector.selector));

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(IDecoder.InvalidSelector.selector));
    }

    function testFallbackDecoderNotAContract() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, decoderEoa);

        assertEq(decoderEoa.code.length, 0);

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function testFallbackCallReverts() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        target.setRevert(true);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});
        decoder.setReturnCalls(calls);

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector,
                address(target),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, uint256(0))
            )
        );
    }

    function testFallbackCallRevertsSecondCall() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        MockTarget targetB = new MockTarget();
        MockTarget targetC = new MockTarget();
        targetB.setRevert(true);

        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});
        calls[1] = Call({target: address(targetB), value: 0, data: SECOND_DATA});
        calls[2] = Call({target: address(targetC), value: 0, data: THIRD_DATA});
        decoder.setReturnCalls(calls);

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector,
                address(targetB),
                abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, uint256(0))
            )
        );
        assertEq(target.callCount(), 0);
        assertEq(targetC.callCount(), 0);
    }

    function testFallbackCallFailCarriesTargetRevertData() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        target.setRevert(true);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: CALL_DATA});
        decoder.setReturnCalls(calls);

        bytes memory targetRevertData =
            abi.encodeWithSelector(MockTarget.MockTargetRevert.selector, uint256(0));

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IReceiverHub.CallFail.selector, address(target), targetRevertData
            )
        );
        assertGt(targetRevertData.length, 0);
    }

    function testFallbackCallInsufficientBalance() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: CALL_VALUE, data: CALL_DATA});
        decoder.setReturnCalls(calls);

        assertEq(address(receiverHub).balance, 0);

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(IReceiverHub.CallFail.selector, address(target), bytes(""))
        );
        assertEq(target.callCount(), 0);
    }

    function testFallbackCallToNonContract() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: eoaTarget, value: 0, data: ""});
        decoder.setReturnCalls(calls);

        assertEq(eoaTarget.code.length, 0);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, DECODER_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
    }

    function testFallbackReentrant() public {
        vm.prank(admin);
        receiverHub.setDecoder(DECODER_SELECTOR, address(decoder));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), value: 0, data: FIRST_DATA});
        decoder.setReturnCalls(calls);

        target.setReenter(address(receiverHub), DISPATCH_CALLDATA, 0);

        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(address(target), DECODER_SELECTOR, address(decoder));
        vm.expectEmit(address(receiverHub));
        emit IReceiverHub.CallsReceived(relayer, DECODER_SELECTOR, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(receiverHub).call(DISPATCH_CALLDATA);

        assertTrue(success);
        assertEq(decoder.decodeCount(), 2);
        assertEq(target.callCount(), 2);
    }

    function testReceive() public {
        vm.deal(relayer, CALL_VALUE);

        vm.prank(admin);
        receiverHub.setDecoder(ZERO_SELECTOR, address(decoder));

        decoder.setReturnCalls(new Call[](0));

        vm.recordLogs();

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call{value: CALL_VALUE}("");

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(address(receiverHub).balance, CALL_VALUE);
        assertEq(decoder.decodeCount(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testReceiveZeroValue() public {
        vm.recordLogs();

        vm.prank(relayer);
        (bool success, bytes memory returnData) = address(receiverHub).call{value: 0}("");

        assertTrue(success);
        assertEq(returnData.length, 0);
        assertEq(address(receiverHub).balance, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }
}
