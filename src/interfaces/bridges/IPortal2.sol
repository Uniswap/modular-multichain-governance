// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

interface IPortal2 {
    /// @notice Creates a deposit transaction to send on OP Stack chains.
    /// @param to Call receiver on remote chain.
    /// @param value Total value, in Ether, to send.
    /// @param gasLimit Gas limit for call on remote chain.
    /// @param isCreation True if the deposit transaction is a contract creation.
    /// @param data Data to send (forwarded directly).
    function depositTransaction(
        address to,
        uint256 value,
        uint64 gasLimit,
        bool isCreation,
        bytes memory data
    ) external payable;
}
