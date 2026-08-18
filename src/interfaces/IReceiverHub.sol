// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IDecoder} from "src/interfaces/modules/IDecoder.sol";
import {Call} from "src/types/Call.sol";

interface IReceiverHub {
    /// @notice Logged when a decoder is registered.
    /// @dev When `newDecoder` is the zero address, the selector becomes un-set. A nonzero
    ///      `oldDecoder` marks the replacement of a live decoder.
    /// @param selector Four byte selector used to dispatch the decoder.
    /// @param oldDecoder Decoder previously registered for the selector, or zero if none.
    /// @param newDecoder Decoder module to decode incoming messages matching the selector.
    event DecoderRegistered(
        bytes4 indexed selector, address indexed oldDecoder, address indexed newDecoder
    );

    /// @notice Logged when a call is received.
    /// @dev The `caller` MAY NOT be a bridge. The `selector` is what dispatches the `decoder`.
    /// @param caller Caller, which may be a bridge contract or a relayer account.
    /// @param selector Calldata selector.
    /// @param decoder Decoder module used to decode the calls.
    event CallsReceived(address indexed caller, bytes4 indexed selector, address indexed decoder);

    /// @notice Maps selectors to decoder modules.
    /// @param selector Selector to use in dispatching.
    /// @return Decoder module.
    function decoders(bytes4 selector) external view returns (address);

    /// @notice Sets the selector-decoder pair.
    /// @param selector Selector to use in dispatching.
    /// @param decoder Decoder module to be dispatched.
    function setDecoder(bytes4 selector, address decoder) external;

    /// @notice Captures bridge messages and dispatches a decoder.
    fallback() external payable;

    /// @dev Does nothing, Solidity compiler throws a warning if this doesn't exist.
    receive() external payable;
}
