// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

import {Pool} from "./Pool.sol";
import {ProfitManager} from "../network/ProfitManager.sol";

/// @notice simple receiver contract for receiving ccip tokens then calling the repay function at the pool.
/// handle the ccip tokens of the pool, previously transfered by the stake function.
contract PoolReceiver is CCIPReceiver {
    using SafeERC20 for IERC20;

    /// @notice pool asigned to this receiver
    address public immutable pool;

    /// @notice ccip token address to receive
    address public immutable ccipToken;

    /// @notice profit manager address
    address public immutable profitManager;
    
    constructor(
        address _router,
        address _pool,
        address _ccipToken,
        address _profitManager
    ) CCIPReceiver(_router) {
        pool = _pool;
        profitManager = _profitManager;
        ccipToken = _ccipToken;
    }

    /// @notice handles the ccip token received and calls the pool repay function
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        require(any2EvmMessage.destTokenAmounts[0].token == ccipToken, "Invalid token");
        bytes32 loanId = abi.decode(any2EvmMessage.data, (bytes32));
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;

        // transfers the ccip token to the pool
        IERC20(ccipToken).approve(address(this), amount);
        IERC20(ccipToken).safeTransferFrom(
            address(this),
            pool,
            amount
        );

        Pool(pool).repay(loanId, amount, true);
    }
}
