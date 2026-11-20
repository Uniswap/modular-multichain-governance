// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

library CCIPError {
    error ReceiverHubCallerNotRouter();
    error InvalidSourceChain();
}
