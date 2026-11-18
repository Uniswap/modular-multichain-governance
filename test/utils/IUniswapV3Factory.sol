// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Owner-facing subset of the deployed Uniswap v3 Factory used by the fork tests.
interface IUniswapV3Factory {
    function owner() external view returns (address);

    function feeAmountTickSpacing(uint24 fee) external view returns (int24);

    function setOwner(address newOwner) external;

    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
}
