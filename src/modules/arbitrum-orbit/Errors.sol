// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

library Errors {
    error CallerNotReceiverHub();
    error NotFromSenderHub();
    error InvalidCalldata();
    error InvalidSelector();
}
