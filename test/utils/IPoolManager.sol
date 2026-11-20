// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Owner-facing subset of the deployed Uniswap v4 PoolManager used by the fork tests.
interface IPoolManager {
    function owner() external view returns (address);

    function protocolFeeController() external view returns (address);

    function transferOwnership(address newOwner) external;

    function setProtocolFeeController(address controller) external;
}
