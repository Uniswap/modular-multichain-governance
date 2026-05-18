// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

struct Call {
    address target;
    uint256 value;
    bytes data;
}
