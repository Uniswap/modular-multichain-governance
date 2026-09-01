// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IPortal2} from "src/interfaces/bridges/IPortal2.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IPortal2Calls} from "src/modules/optimism-portal2/IPortal2Calls.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract Portal2Encoder is Owned(msg.sender), IEncoder {
    event SetGasLimit(uint64 gasLimit);

    event SetPortal(uint256 indexed chainId, address indexed portal);

    uint64 public gasLimit;

    mapping(uint256 chainId => address) public portals;

    function setGasLimit(uint64 newGasLimit) external onlyOwner {
        gasLimit = newGasLimit;

        emit SetGasLimit(newGasLimit);
    }

    function setPortal(uint256 chainId, address portal) external onlyOwner {
        portals[chainId] = portal;

        emit SetPortal(chainId, portal);
    }

    function encode(address receiverHub, MultichainAction calldata multichainAction)
        public
        view
        returns (Call[] memory)
    {
        require(receiverHub != address(0x00), InvalidReceiverHub());

        address portal = portals[multichainAction.chainId];

        require(portal != address(0x00), BridgeNotSet());

        uint256 value = 0;

        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        Call[] memory bridgeCalls = new Call[](1);

        bridgeCalls[0] = Call({
            target: portal,
            value: value,
            data: abi.encodeCall(
                IPortal2.depositTransaction,
                (
                    receiverHub,
                    value,
                    gasLimit,
                    false,
                    abi.encodeCall(IPortal2Calls.portal2Call, (multichainAction.calls))
                )
            )
        });

        return bridgeCalls;
    }
}
