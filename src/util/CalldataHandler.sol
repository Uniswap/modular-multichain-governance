// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

library CalldataHandler {
    function getSelector(bytes calldata encodedCall) internal pure returns (bytes4) {
        bytes4 selector;

        assembly ("memory-safe") {
            selector := calldataload(encodedCall.offset)

            selector := shl(0xe0, shr(0xe0, selector))
        }

        return selector;
    }

    function getCalldataWithoutSelector(bytes calldata encodedCall) internal pure returns (bytes memory) {
        bytes memory data;

        assembly ("memory-safe") {
            data := mload(0x40)

            mstore(data, encodedCall.length)

            calldatacopy(encodedCall.offset, add(data, 0x20), encodedCall.length)

            mstore(0x40, add(data, encodedCall.length))
        }

        return data;
    }
}
