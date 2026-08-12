// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IBridgeCalls} from "src/interfaces/modules/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {IWormhole} from "src/interfaces/bridges/IWormhole.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract WormholeEncoder is IEncoder, Owned(msg.sender) {
    uint8 public constant CONSISTENCY_LEVEL = 1;

    address public immutable WORMHOLE;

    uint32 public nonce;
    mapping(uint256 chainId => uint16) public wormholeChainIds;

    constructor(address wormhole) {
        WORMHOLE = wormhole;
    }

    function setWormholeChainIds(uint256[] calldata eip155ChainIds, uint16[] calldata whChainIds) public onlyOwner {
        require(eip155ChainIds.length == whChainIds.length);

        for (uint256 i; i < eip155ChainIds.length; i++) {
            uint256 eip155ChainId = eip155ChainIds[i];
            uint16 wormholeChainId = whChainIds[i];

            wormholeChainIds[eip155ChainId] = wormholeChainId;
        }
    }

    function encode(MultichainAction calldata multichainAction)
        public
        returns (address, uint256, bytes memory)
    {
        uint256 messageFee = IWormhole(WORMHOLE).messageFee();

        uint256 value = 0;
        for (uint256 i; i < multichainAction.calls.length; i++) {
            value += multichainAction.calls[i].value;
        }

        nonce += 1;

        return (
            WORMHOLE,
            messageFee + value,
            abi.encodeCall(
                IWormhole.publishMessage,
                (
                    nonce,
                    abi.encodeCall(
                        IBridgeCalls.wormholeCall,
                        abi.encode(
                            wormholeChainIds[multichainAction.chainId], multichainAction.calls
                        )
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }
}
