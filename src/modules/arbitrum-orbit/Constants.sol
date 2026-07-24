// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Constants {
    uint160 internal constant ARBITRUM_ALIAS = uint160(0x1111000000000000000000000000000000001111);

    function addAlias(address l1Address) internal pure returns (address l2Address) {
        // overflow is intended behavior.
        unchecked {
            l2Address = address(uint160(l1Address) + ARBITRUM_ALIAS);
        }
    }

    function removeAlias(address l2Address) internal pure returns (address l1Address) {
        // overflow is intended behavior.
        unchecked {
            l1Address = address(uint160(l2Address) - ARBITRUM_ALIAS);
        }
    }
}
