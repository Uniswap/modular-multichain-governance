// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {MultichainAction} from "src/types/MultichainAction.sol";

interface ISenderHub {
    /// @notice Logged when encoder is set.
    /// @param chainId Chain the encoder targets.
    /// @param encoder Encoder moudule.
    event SetEncoder(uint256 indexed chainId, address indexed encoder);

    /// @notice Logged when a multichain action is sent.
    /// @param chainId Chain the action targets.
    /// @param bridge Bridge address to be called (returned by `encoder`).
    /// @param encoder Encoder module.
    event SendMultichainAction(
        uint256 indexed chainId, address indexed bridge, address indexed encoder
    );

    /// @notice Logged when a receiver hub is set.
    /// @param chainId Chain where the `receiverHub` exists.
    /// @param receiverHub Receiver hub on the remote chain.
    event SetReceiverHub(uint256 indexed chainId, address indexed receiverHub);

    /// @notice Maps chain Id's to encoder modules.
    /// @param chainId Chain the encoder targets.
    /// @return Encoder module.
    function encoders(uint256 chainId) external view returns (address);

    /// @notice Maps chain Id's to receiver hubs
    /// @param chainId Chain where the `receiverHub` exists.
    /// @return Receiver Hub.
    function receiverHubs(uint256 chainId) external view returns (address);

    /// @notice Sets encoder to chain Id.
    /// @param chainId Chain Id.
    /// @param encoder Encoder module.
    function setEncoder(uint256 chainId, address encoder) external;

    /// @notice Sets receiver hub to chain Id.
    /// @param chainId Chain Id.
    //// @param receiverHub Receiver hub.
    function setReceiverHub(uint256 chainId, address receiverHub) external;

    /// @notice Sends an array of multichain actions.
    /// @param actions Multichain actions.
    function sendMultichainActions(MultichainAction[] calldata actions) external;
}
