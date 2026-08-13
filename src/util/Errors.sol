// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

library DecoderError {
    error InvalidReceiverHubCaller();
    error CallerNotReceiverHub();
    error NotFromSenderHub();
    error CalldataTooShort();
    error InvalidSelector();
}

library WormholeError {
    error ParseVerifyVM(string wormholeReason);
    error NotFromEthereum();
    error Expired();
    error InvalidNonce();
    error MessageVersion();
    error NotToReceiverHub();
    error NotToThisChain();
}
