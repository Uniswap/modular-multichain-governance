// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BridgeRegistry} from "src/BridgeRegistry.sol";
import {IEncoder} from "src/interfaces/IEncoder.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";
import {Call} from "src/types/Call.sol";

interface IWormholeRelayer {
    function quoteEVMDeliveryPrice(uint16 targetChain, uint256 receiverValue, uint256 gasLimit)
        external
        view
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused);

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes calldata payload,
        uint256 receiverValue,
        uint256 gasLimit
    ) external payable returns (uint64 sequence);
}

contract WormholeEncoder is IEncoder {
    BridgeRegistry public bridgeRegistry;
    IWormholeRelayer public wormholeRelayer;

    function encode(MultichainAction calldata multichainAction) external view returns (address, uint256, bytes memory) {
        uint16 targetChain = _chainIdToWormholeChainId(multichainAction.chainId);
        uint256 gasLimit = 2_000_00;
        address receiverHub = bridgeRegistry.receiverHubs(multichainAction.bridgeId);

        uint256 totalValue = 0;
        for (uint256 i; i < multichainAction.calls.length; i++) {
            totalValue += multichainAction.calls[i].value;
        }

        (uint256 quote, ) = wormholeRelayer.quoteEVMDeliveryPrice(targetChain, totalValue, gasLimit);

        return (
            address(wormholeRelayer),
            quote,
            abi.encodeCall(
                IWormholeRelayer.sendPayloadToEvm,
                (
                    targetChain,
                    receiverHub,
                    abi.encode(multichainAction.messageType, multichainAction.calls),
                    totalValue,
                    gasLimit
                )
            )
        );
    }

    function _chainIdToWormholeChainId(uint256 chainId) internal pure returns (uint16) {
        return uint16(chainId);
    }
}
