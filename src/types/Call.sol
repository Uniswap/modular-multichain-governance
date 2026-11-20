// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @dev Call data type.
struct Call {
    address target;
    uint256 value;
    bytes data;
}
