// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ISenderHub} from "src/interfaces/ISenderHub.sol";
import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract Portal2Encoder is Owned(msg.sender), IEncoder {
    event SetGasLimit(uint64 gasLimit);

    event SetPortal(uint256 indexed chainId, address indexed portal);

    address public immutable SENDER_HUB;

    uint64 public gasLimit;

    mapping(uint256 chainId => address) public portals;

    constructor(address senderHub) {
        SENDER_HUB = senderHub;
    }

    function setGasLimit(uint64 newGasLimit) external onlyOwner {
        gasLimit = newGasLimit;

        emit SetGasLimit(newGasLimit);
    }

    function setPortal(uint256 chainId, address portal) external onlyOwner {
        portals[chainId] = portal;

        emit SetPortal(chainId, portal);
    }

    function encode(MultichainAction calldata multichainAction)
        public
        view
        returns (address, uint256, bytes memory)
    {
        address portal = portals[multichainAction.chainId];

        address receiverHub = ISenderHub(SENDER_HUB).receiverHubs(multichainAction.chainId);
        uint256 value = 0;

        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        return (
            portal,
            value,
            abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    value,
                    gasLimit,
                    false,
                    abi.encodeCall(IBridgeCalls.portal2Call, (multichainAction.calls))
                )
            )
        );
    }
}
