// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {EVM2AnyMessage, EVMTokenAmount, IRouterClient} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

contract CCIPEncoder is Owned(msg.sender), IEncoder {
    event SetCcipChainSelector(uint256 indexed chainId, uint64 indexed ccipChainSelector);

    address public immutable SENDER_HUB;
    address public immutable ROUTER;

    bytes4 internal constant GENERIC_EXTRA_ARGS_V2 = 0x181dcf10;
    bool internal constant ALLOW_OUT_OF_ORDER_EXEC = false;

    mapping(uint256 chainId => uint64) public ccipChainSelectors;

    constructor(address senderHub, address router) {
        SENDER_HUB = senderHub;
        ROUTER = router;
    }

    function setCcipChainSelector(uint256 chainId, uint64 ccipChainSelector) public {
        ccipChainSelectors[chainId] = ccipChainSelector;

        emit SetCcipChainSelector(chainId, ccipChainSelector);
    }

    function encode(address receiverHub, MultichainAction calldata multichainAction)
        public
        view
        returns (Call[] memory)
    {
        uint256 gasLimit = estimateGas(multichainAction);
        uint64 targetChainSelector = ccipChainSelectors[multichainAction.chainId];

        EVM2AnyMessage memory message = EVM2AnyMessage({
            receiver: abi.encode(receiverHub),
            data: abi.encode(multichainAction.calls),
            tokenAmounts: new EVMTokenAmount[](0),
            feeToken: address(0x00),
            extraArgs: abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2, gasLimit, ALLOW_OUT_OF_ORDER_EXEC
            )
        });

        uint256 fee = IRouterClient(ROUTER).getFee(targetChainSelector, message);

        Call[] memory calls = new Call[](1);

        calls[0] = Call({
            target: ROUTER,
            value: fee,
            data: abi.encodeCall(IRouterClient.ccipSend, (targetChainSelector, message))
        });

        return calls;
    }

    /// @notice Estimates gas for message
    /// @dev TODO: Define this as gas can range somewhat widely depending on the scope of governance
    /// actions on the target chain and the router does NOT refund gas. For now we leave it at the
    /// default of 2,000,000.
    function estimateGas(MultichainAction calldata) public pure returns (uint256) {
        return 2_000_000;
    }
}
