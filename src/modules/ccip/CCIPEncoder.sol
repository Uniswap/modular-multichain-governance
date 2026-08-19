// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {IEncoder} from "src/interfaces/modules/IEncoder.sol";
import {EVM2AnyMessage, EVMTokenAmount, IRouterClient} from "src/modules/ccip/IRouterClient.sol";
import {Call} from "src/types/Call.sol";
import {MultichainAction} from "src/types/MultichainAction.sol";

/// @title Chainlink CCIP Encoder.
/// @notice Encodes messages for the Chainlink CCIP Router.
/// @dev Chainlink maintains a custom list of "chain selectors" unique to each chain. We map the
///      EIP-155 chain Id's to CCIP's chain selectors to abstract the complexity of finding the
///      appropriate chain selector.
contract CCIPEncoder is Owned(msg.sender), IEncoder {
    /// @notice Logged when an EIP-155 chain Id is mapped to a CCIP chain selector.
    /// @param chainId EIP-155 chain Id.
    /// @param ccipChainSelector CCIP chain selector.
    event SetCcipChainSelector(uint256 indexed chainId, uint64 indexed ccipChainSelector);

    /// @notice CCIP Router contract.
    address public immutable ROUTER;

    /// @dev Arbitrary CCIP selector for "extraArgs" parameter.
    bytes4 internal constant GENERIC_EXTRA_ARGS_V2 = 0x181dcf10;

    /// @dev If true, sequencing of messages is not enforced.
    bool internal constant ALLOW_OUT_OF_ORDER_EXEC = false;

    /// @notice Maps EIP-155 chain Id's to CCIP chain selectors.
    mapping(uint256 chainId => uint64) public ccipChainSelectors;

    constructor(address router) {
        ROUTER = router;
    }

    /// @notice Sets the CCIP chain selector for a given EIP-155 chain Id.
    /// @param chainId EIP-155 chain Id.
    /// @param ccipChainSelector CCIP chain selector.
    function setCcipChainSelector(uint256 chainId, uint64 ccipChainSelector) public onlyOwner {
        ccipChainSelectors[chainId] = ccipChainSelector;

        emit SetCcipChainSelector(chainId, ccipChainSelector);
    }

    /// @notice Encodes a multichain action for the CCIP Router.
    /// @dev The local CCIP Router is the same for all remote networks.
    /// @param multichainAction Action to send to the Receiver Hub on the remote chain.
    /// @return Bridge call(s) for SenderHub to make.
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
