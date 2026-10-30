// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

library WormholeError {
    error ParseVerifyVM(string wormholeReason);
    error NotFromEthereum();
    error Expired();
    error InvalidNonce();
    error MessageVersion();
    error NotToReceiverHub();
    error NotToThisChain();
}
