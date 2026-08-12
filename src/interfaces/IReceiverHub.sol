// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";

interface ReceiverHub {
    event DecoderRegistered(bytes4 indexed selector, address indexed decoder);
    event CallsReceived(address indexed bridge, address indexed decoder, bytes32 indexed callsHash);

    function decoders(bytes4 selector) external view returns (address);

    function setDecoder(bytes4 selector, address decoder) external;

    fallback() external payable;

    receive() external payable;
}
