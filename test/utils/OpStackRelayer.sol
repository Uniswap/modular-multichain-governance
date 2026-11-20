// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {IOptimismPortal2} from "test/utils/IOptimismPortal2.sol";

/// @title OP Stack Relayer
/// @notice Stands in for the OP Stack derivation pipeline in fork tests. Reads the deposits an
///         OptimismPortal2 logged on the L1 fork and replays them as deposit transactions on
///         whichever fork is active.
/// @dev The replay follows deposit transaction semantics where they matter to the hubs:
///
///      - the sender is the `from` the portal logged (already aliased), as caller and origin
///      - the mint is credited to the sender whether or not the call succeeds
///      - the call runs with the deposit's gas limit less its intrinsic gas
///      - a failed call reverts everything but the mint, and is never retried
///
///      Gas is close but not exact, accounts and slots touched earlier in the same test are warm
///      here and would be cold in a real deposit, so this slightly overstates the gas available.
library OpStackRelayer {
    /// @dev Deposit transaction derived from a `TransactionDeposited` log.
    struct Deposit {
        address from;
        address to;
        uint256 mint;
        uint256 value;
        uint64 gasLimit;
        bool isCreation;
        bytes data;
    }

    /// @notice Thrown when the log is not a version zero deposit.
    error UnsupportedDepositVersion(uint256 version);

    /// @notice Thrown when relaying a contract creation, which the modules never send.
    error CreationNotSupported();

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Byte length of the packed `mint`, `value`, `gasLimit` and `isCreation` fields.
    uint256 private constant OPAQUE_HEADER_LENGTH = 73;

    /// @dev Stipend the EVM adds to a call carrying value, which a transaction does not get.
    uint256 private constant CALL_STIPEND = 2300;

    /// @notice Extracts the deposits `portal` logged, in order.
    /// @param logs Logs recorded on the L1 fork with `vm.recordLogs`.
    /// @param portal Portal to read deposits from, logs from other emitters are skipped.
    function deposits(Vm.Log[] memory logs, address portal)
        internal
        pure
        returns (Deposit[] memory found)
    {
        found = new Deposit[](logs.length);
        uint256 count;

        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.emitter != portal) continue;
            if (log.topics[0] != IOptimismPortal2.TransactionDeposited.selector) continue;

            uint256 version = uint256(log.topics[3]);
            require(version == 0, UnsupportedDepositVersion(version));

            bytes memory opaqueData = abi.decode(log.data, (bytes));
            bytes memory data = new bytes(opaqueData.length - OPAQUE_HEADER_LENGTH);

            uint256 mint;
            uint256 value;
            uint64 gasLimit;
            bool isCreation;

            // opaqueData is packed as:
            //
            // | mint (32) | value (32) | gasLimit (8) | isCreation (1) | data |
            assembly ("memory-safe") {
                mint := mload(add(opaqueData, 0x20))
                value := mload(add(opaqueData, 0x40))
                gasLimit := shr(192, mload(add(opaqueData, 0x60)))
                isCreation := byte(0, mload(add(opaqueData, 0x68)))
                mcopy(add(data, 0x20), add(opaqueData, 0x69), mload(data))
            }

            found[count++] = Deposit({
                from: address(uint160(uint256(log.topics[1]))),
                to: address(uint160(uint256(log.topics[2]))),
                mint: mint,
                value: value,
                gasLimit: gasLimit,
                isCreation: isCreation,
                data: data
            });
        }

        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    /// @notice Replays a deposit on the active fork.
    /// @return success False if the deposit transaction would have failed on L2.
    /// @return returnData Data returned or reverted by the receiver.
    function relay(Deposit memory deposit)
        internal
        returns (bool success, bytes memory returnData)
    {
        require(!deposit.isCreation, CreationNotSupported());

        VM.deal(deposit.from, deposit.from.balance + deposit.mint);

        uint256 intrinsic = intrinsicGas(deposit.data);
        if (deposit.gasLimit < intrinsic) return (false, "");

        uint256 gas = deposit.gasLimit - intrinsic;
        if (deposit.value != 0) gas = gas > CALL_STIPEND ? gas - CALL_STIPEND : 0;

        VM.prank(deposit.from, deposit.from);
        (success, returnData) = deposit.to.call{value: deposit.value, gas: gas}(deposit.data);
    }

    /// @notice Gas charged to a transaction before execution, base cost plus calldata.
    function intrinsicGas(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;

        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0x00 ? 4 : 16;
        }
    }
}
