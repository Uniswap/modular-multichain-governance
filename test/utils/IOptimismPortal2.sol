// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

/// @notice Subset of the deployed OptimismPortal2 used by the fork tests. The modules do not call
///         the portal, the L1CrossDomainMessenger deposits on it for them.
interface IOptimismPortal2 {
    /// @notice Thrown when the deposit's calldata is larger than 120,000 bytes.
    error OptimismPortal_CalldataTooLarge();

    /// @notice Thrown by the portal's resource metering when a deposit asks for more gas than the
    ///         L2 has left to sell in the current L1 block.
    error OutOfGas();

    /// @notice Logged for every deposit, this is what the L2 derives the deposit transaction from.
    /// @param from Sender on L2, aliased if the L1 caller is a contract.
    /// @param to Call receiver on L2.
    /// @param version Deposit version, always zero.
    /// @param opaqueData `abi.encodePacked(msg.value, value, gasLimit, isCreation, data)`.
    event TransactionDeposited(
        address indexed from, address indexed to, uint256 indexed version, bytes opaqueData
    );
}
