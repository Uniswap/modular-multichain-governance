// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

library Errors {
    error CallerNotReceiverHub();
    error InvalidSelector();
    error WormholeParseVerifyVM(string wormholeReason);
    error NotFromSenderHub();
    error NotFromEthereum();
    error Expired();
    error InvalidNonce();
    error MessageVersion();
    error NotToReceiverHub();
    error NotToThisChain();
    error LengthMismatch();
}
