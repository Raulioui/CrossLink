//SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/// @notice Alow users to make transactions of CCIP to another chains at the protocol.
contract PersonalAccount is OwnerIsCreator {
    
    IERC20 public linkToken;
    IRouterClient public router;
    address public ccipToken;

    constructor(
        address _linkToken,
        address _router,
        address _ccipToken
    ) {
        linkToken = IERC20(_linkToken);
        router = IRouterClient(_router);
        ccipToken = _ccipToken;
    }

    function stake(address gToken, uint256 amount, uint64 chainSelector, address pool, address staker) external onlyOwner {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: ccipToken,
            amount: amount
        });

        Client.EVM2AnyMessage memory evm2AnyMessage =
            Client.EVM2AnyMessage({
                receiver: abi.encode(gToken), // ABI-encoded receiver address
                data: abi.encode(pool, staker),
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 2_000_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: address(linkToken)
            });

        // Get the fee required to send the message
        uint256 fees = router.getFee(chainSelector, evm2AnyMessage);

        require(fees <= linkToken.balanceOf(address(this)), "Not enough LINK to pay fees");

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        linkToken.approve(address(router), fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(ccipToken).approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        router.ccipSend(chainSelector, evm2AnyMessage);
    }

    /// @dev call getBidDetail at AuctionManager before calling this function
    function bid(bytes32 loanId, address auctionManager, uint256 amount, uint64 chainSelector) external onlyOwner {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: ccipToken,
            amount: amount
        });

        Client.EVM2AnyMessage memory evm2AnyMessage =
            Client.EVM2AnyMessage({
                receiver: abi.encode(auctionManager), // ABI-encoded receiver address
                data: abi.encode(loanId), // ABI-encoded data
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 2_000_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: address(linkToken)
            });

        // Get the fee required to send the message
        uint256 fees = router.getFee(chainSelector, evm2AnyMessage);

        require(fees <= linkToken.balanceOf(address(this)), "Not enough LINK to pay fees");

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        linkToken.approve(address(router), fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(ccipToken).approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        router.ccipSend(chainSelector, evm2AnyMessage);
    }

    function repay(address poolReceiver, bytes32 loanId, uint256 amount, uint64 chainSelector) external onlyOwner {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: ccipToken,
            amount: amount
        });

        Client.EVM2AnyMessage memory evm2AnyMessage =
            Client.EVM2AnyMessage({
                receiver: abi.encode(poolReceiver), // ABI-encoded receiver address
                data: abi.encode(loanId), // ABI-encoded data
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 2_000_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: address(linkToken)
            });

        // Get the fee required to send the message
        uint256 fees = router.getFee(chainSelector, evm2AnyMessage);

        require(fees <= linkToken.balanceOf(address(this)), "Not enough LINK to pay fees");

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        linkToken.approve(address(router), fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(ccipToken).approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        router.ccipSend(chainSelector, evm2AnyMessage);
    }
}