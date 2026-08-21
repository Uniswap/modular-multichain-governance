// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

library CCIPError {
    error ReceiverHubCallerNotRouter();
    error InvalidSourceChain();
}
