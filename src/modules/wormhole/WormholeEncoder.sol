// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IBridgeCalls} from "src/interfaces/IBridgeCalls.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

interface IWormhole {
    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence);
    function messageFee() external view returns (uint256);
}

contract WormholeEncoder is IEncoder, Owned(msg.sender) {
    uint8 public constant CONSISTENCY_LEVEL = 1;

    address public immutable WORMHOLE;
    address public immutable BRIDGE_REGISTRY;

    uint32 public nonce;
    mapping(uint256 chainId => uint16) public toWormholeChainId;

    constructor(address wormhole, address bridgeRegistry) {
        WORMHOLE = wormhole;
        BRIDGE_REGISTRY = bridgeRegistry;
    }

    function setWormholeChainId(uint256 realChainId, uint16 wormholeChainId) public onlyOwner {
        toWormholeChainId[realChainId] = wormholeChainId;
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
                            toWormholeChainId[multichainAction.chainId], multichainAction.calls
                        )
                    ),
                    CONSISTENCY_LEVEL
                )
            )
        );
    }
}
