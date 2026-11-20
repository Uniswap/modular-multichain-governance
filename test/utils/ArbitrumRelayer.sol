// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.37;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {IArbitrumBridge} from "test/utils/IArbitrumBridge.sol";
import {IArbitrumInbox} from "test/utils/IArbitrumInbox.sol";

/// @title Arbitrum Relayer
/// @notice Stands in for ArbOS in fork tests, which Foundry does not run. Reads the retryable
///         tickets an Inbox logged on the L1 fork and plays them out on whichever fork is active.
/// @dev The replay follows retryable ticket semantics where they matter to the hubs:
///
///      - the sender is the `sender` the bridge logged (always aliased), as caller and origin
///      - the deposit is credited to the sender, which then pays the submission fee and the gas
///      - the call value waits in an escrow account, on neither the sender nor the receiver
///      - the first attempt runs with the ticket's gas limit less its intrinsic gas, and only if
///        the gas limit and the max fee per gas can pay for a transaction at all
///      - a failed or skipped attempt reverts the call alone, the ticket stays live and can be
///        redeemed again with donated gas, or canceled
///      - whatever the deposit does not spend goes to the excess fee refund address, and a
///        canceled ticket's call value to the call value refund address
///
///      Where it departs from ArbOS: fees are burned rather than paid to the chain's fee accounts,
///      the escrow is not the account ArbOS derives, tickets do not expire, and a manual redeem
///      charges no one for its gas.
///
///      Gas is close but not exact, accounts and slots touched earlier in the same test are warm
///      here and would be cold in a real attempt, so this slightly overstates the gas available.
///      The unused gas refunded after an attempt is measured around the call and is as rough.
library ArbitrumRelayer {
    /// @dev Retryable ticket derived from an `InboxMessageDelivered` log and the bridge's
    ///      `MessageDelivered` log for the same message.
    struct Ticket {
        uint256 messageNum;
        address from;
        uint256 l1BaseFee;
        address to;
        uint256 l2CallValue;
        uint256 deposit;
        uint256 maxSubmissionCost;
        address excessFeeRefundAddress;
        address callValueRefundAddress;
        uint256 gasLimit;
        uint256 maxFeePerGas;
        bytes data;
    }

    /// @dev Where a ticket is in its life on the active fork.
    enum Status {
        Pending,
        Live,
        Closed
    }

    /// @dev Ticket statuses, kept in the calling test's storage, which persists across forks.
    struct Storage {
        mapping(bytes32 id => Status) statuses;
    }

    /// @notice Thrown when the bridge logged no delivery for a message the Inbox logged.
    error DeliveryNotFound(uint256 messageNum);

    /// @notice Thrown when a ticket's length does not match the calldata length it declares.
    error MalformedTicket();

    /// @notice Thrown when relaying a contract creation, which the modules never send.
    error CreationNotSupported();

    /// @notice Thrown when relaying a ticket twice.
    error TicketAlreadyRelayed();

    /// @notice Thrown when redeeming or canceling a ticket that was never relayed, has been
    ///         redeemed, or has been canceled.
    error TicketNotLive();

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant STORAGE_SLOT = keccak256("test.utils.ArbitrumRelayer");

    /// @dev Offset the Inbox applies to the L1 sender of every message.
    uint160 private constant ALIAS = uint160(0x1111000000000000000000000000000000001111);

    /// @dev Kind the bridge logs for a retryable ticket.
    uint8 private constant KIND_SUBMIT_RETRYABLE = 9;

    /// @dev Byte length of the nine words before a ticket's calldata.
    uint256 private constant HEADER_LENGTH = 288;

    /// @dev Gas a ticket must be able to pay for before ArbOS attempts it, the cost of a transfer.
    uint256 private constant TX_GAS = 21_000;

    /// @dev Stipend the EVM adds to a call carrying value, which a transaction does not get.
    uint256 private constant CALL_STIPEND = 2300;

    /// @notice Address a message from `l1Address` is sent from on L2.
    function applyAlias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + ALIAS);
        }
    }

    /// @notice Extracts the retryable tickets `inbox` logged, in order.
    /// @param logs Logs recorded on the L1 fork with `vm.recordLogs`.
    /// @param inbox Inbox to read tickets from, logs from other emitters and messages of other
    ///        kinds are skipped.
    function tickets(Vm.Log[] memory logs, address inbox)
        internal
        pure
        returns (Ticket[] memory found)
    {
        found = new Ticket[](logs.length);
        uint256 count;

        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.emitter != inbox) continue;
            if (log.topics[0] != IArbitrumInbox.InboxMessageDelivered.selector) continue;

            uint256 messageNum = uint256(log.topics[1]);
            (uint8 kind, address sender, uint256 l1BaseFee) = delivery(logs, i, inbox, messageNum);

            if (kind != KIND_SUBMIT_RETRYABLE) continue;

            Ticket memory ticket = decode(abi.decode(log.data, (bytes)));
            ticket.messageNum = messageNum;
            ticket.from = sender;
            ticket.l1BaseFee = l1BaseFee;

            found[count++] = ticket;
        }

        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    /// @notice Submits a ticket on the active fork and makes the first attempt at its call.
    /// @return success False if the attempt failed or was skipped, the ticket is then still live.
    /// @return returnData Data returned or reverted by the receiver, empty if skipped.
    function relay(Ticket memory ticket) internal returns (bool success, bytes memory returnData) {
        require(ticket.to != address(0x00), CreationNotSupported());

        bytes32 id = ticketId(ticket);
        require(store().statuses[id] == Status.Pending, TicketAlreadyRelayed());
        store().statuses[id] = Status.Live;

        // The Inbox has checked on L1 that the deposit covers the call value, the max submission
        // cost and the gas, and that the max submission cost covers the fee, so none of the
        // amounts below can exceed the sender's balance.
        uint256 submissionFee = (1400 + 6 * ticket.data.length) * ticket.l1BaseFee;

        mint(ticket.from, ticket.deposit);
        burn(ticket.from, submissionFee);
        transfer(
            ticket.from, ticket.excessFeeRefundAddress, ticket.maxSubmissionCost - submissionFee
        );
        transfer(ticket.from, escrow(ticket), ticket.l2CallValue);

        uint256 baseFee = block.basefee;

        // ArbOS skips the attempt if the ticket cannot pay for a transaction at the current base
        // fee, and refunds all of the gas it committed.
        if (ticket.gasLimit < TX_GAS || ticket.maxFeePerGas < baseFee) {
            transfer(
                ticket.from, ticket.excessFeeRefundAddress, ticket.gasLimit * ticket.maxFeePerGas
            );

            return (false, "");
        }

        burn(ticket.from, ticket.gasLimit * baseFee);
        transfer(
            ticket.from,
            ticket.excessFeeRefundAddress,
            ticket.gasLimit * (ticket.maxFeePerGas - baseFee)
        );

        uint256 gasLeft;
        (success, returnData, gasLeft) = attempt(ticket, ticket.gasLimit);

        // The submission fee is refunded if the first attempt succeeds, unused gas either way.
        if (success) mint(ticket.excessFeeRefundAddress, submissionFee);
        mint(ticket.excessFeeRefundAddress, gasLeft * baseFee);
    }

    /// @notice Attempts a live ticket's call again on the active fork, as anyone can on L2 by
    ///         calling `ArbRetryableTx.redeem`.
    /// @param gas Gas the redeemer donates to the attempt.
    /// @return success False if the attempt failed, the ticket is then still live.
    /// @return returnData Data returned or reverted by the receiver.
    function redeem(Ticket memory ticket, uint256 gas)
        internal
        returns (bool success, bytes memory returnData)
    {
        require(store().statuses[ticketId(ticket)] == Status.Live, TicketNotLive());

        (success, returnData,) = attempt(ticket, gas);
    }

    /// @notice Cancels a live ticket on the active fork, as its call value refund address can on
    ///         L2 by calling `ArbRetryableTx.cancel`. A ticket left to expire ends the same way.
    function cancel(Ticket memory ticket) internal {
        bytes32 id = ticketId(ticket);
        require(store().statuses[id] == Status.Live, TicketNotLive());
        store().statuses[id] = Status.Closed;

        transfer(escrow(ticket), ticket.callValueRefundAddress, ticket.l2CallValue);
    }

    /// @notice Account holding a ticket's call value on the active fork while the ticket is live.
    function escrow(Ticket memory ticket) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("escrow", ticketId(ticket))))));
    }

    /// @notice Gas charged to a transaction before execution, base cost plus calldata.
    function intrinsicGas(bytes memory data) internal pure returns (uint256 gas) {
        gas = TX_GAS;

        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0x00 ? 4 : 16;
        }
    }

    /// @dev Runs a ticket's call with `gas` as the transaction's gas limit, `gasLeft` is what of
    ///      it the attempt did not use.
    function attempt(Ticket memory ticket, uint256 gas)
        private
        returns (bool success, bytes memory returnData, uint256 gasLeft)
    {
        uint256 intrinsic = intrinsicGas(ticket.data);
        if (gas < intrinsic) return (false, "", 0);

        uint256 callGas = gas - intrinsic;
        if (ticket.l2CallValue != 0) callGas = callGas > CALL_STIPEND ? callGas - CALL_STIPEND : 0;

        transfer(escrow(ticket), ticket.from, ticket.l2CallValue);

        VM.prank(ticket.from, ticket.from);
        uint256 gasBefore = gasleft();
        (success, returnData) = ticket.to.call{value: ticket.l2CallValue, gas: callGas}(ticket.data);
        uint256 gasUsed = intrinsic + gasBefore - gasleft();

        gasLeft = gas > gasUsed ? gas - gasUsed : 0;

        if (success) {
            store().statuses[ticketId(ticket)] = Status.Closed;
        } else {
            transfer(ticket.from, escrow(ticket), ticket.l2CallValue);
        }
    }

    /// @dev Finds the bridge's log for message `messageNum` of `inbox`, which precedes the
    ///      Inbox's own log at `index`.
    function delivery(Vm.Log[] memory logs, uint256 index, address inbox, uint256 messageNum)
        private
        pure
        returns (uint8, address, uint256)
    {
        for (uint256 i = index; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];

            if (log.topics.length != 3) continue;
            if (log.topics[0] != IArbitrumBridge.MessageDelivered.selector) continue;
            if (uint256(log.topics[1]) != messageNum) continue;

            (address deliveredBy, uint8 kind, address sender,, uint256 l1BaseFee,) =
                abi.decode(log.data, (address, uint8, address, bytes32, uint256, uint64));

            if (deliveredBy == inbox) return (kind, sender, l1BaseFee);
        }

        revert DeliveryNotFound(messageNum);
    }

    /// @dev Decodes the data the Inbox logged for a retryable ticket, packed as:
    ///
    ///      | to | l2CallValue | deposit | maxSubmissionCost | excessFeeRefundAddress |
    ///      | callValueRefundAddress | gasLimit | maxFeePerGas | data length | data |
    ///
    ///      Every field before `data` is a word.
    function decode(bytes memory messageData) private pure returns (Ticket memory ticket) {
        require(messageData.length >= HEADER_LENGTH, MalformedTicket());

        ticket.to = address(uint160(word(messageData, 0)));
        ticket.l2CallValue = word(messageData, 1);
        ticket.deposit = word(messageData, 2);
        ticket.maxSubmissionCost = word(messageData, 3);
        ticket.excessFeeRefundAddress = address(uint160(word(messageData, 4)));
        ticket.callValueRefundAddress = address(uint160(word(messageData, 5)));
        ticket.gasLimit = word(messageData, 6);
        ticket.maxFeePerGas = word(messageData, 7);

        uint256 dataLength = word(messageData, 8);
        require(messageData.length == HEADER_LENGTH + dataLength, MalformedTicket());

        bytes memory data = new bytes(dataLength);

        assembly ("memory-safe") {
            mcopy(add(data, 0x20), add(messageData, 0x140), dataLength)
        }

        ticket.data = data;
    }

    /// @dev Reads the word at `index` of `data`.
    function word(bytes memory data, uint256 index) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(data, add(0x20, mul(index, 0x20))))
        }
    }

    /// @dev Identifies a ticket on the active fork. Not the id ArbOS gives it, which is the hash
    ///      of the transaction that submits it.
    function ticketId(Ticket memory ticket) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, ticket.messageNum));
    }

    function store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;

        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    function mint(address account, uint256 amount) private {
        VM.deal(account, account.balance + amount);
    }

    function burn(address account, uint256 amount) private {
        VM.deal(account, account.balance - amount);
    }

    function transfer(address from, address to, uint256 amount) private {
        burn(from, amount);
        mint(to, amount);
    }
}
