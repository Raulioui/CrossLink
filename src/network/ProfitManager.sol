// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

import {GovernanceToken} from "../tokens/GovernanceToken.sol";
import {Pool} from "../pool/Pool.sol";

/** 
@title ProfitManager
@notice This contract manages profits generated in the system and how it is distributed
    between the various stakeholders.

    This contract also manages a surplus buffer, which acts as first-loss capital in case of
    bad debt. When bad debt is created beyond the surplus buffer, this contract decrements
    the `ccipTokenValue` value held in its storage, which has the effect of reducing the
    value of CCIP token everywhere in the system.

    When a loan generates profit (interests), the profit is traced back to users voting for
    this pool (gauge), which subsequently allows pro-rata distribution of profits to
    the governance tokens holders that vote for the most productive gauges.

    Seniority stack of the debt, in case of losses :
    - global surplus buffer
    - finally, CCIP holders (by updating down the ccipTokenValue)
*/
contract ProfitManager is OwnerIsCreator {
    using SafeERC20 for IERC20;

    /**
     * @notice Events
    */

    /// @notice emitted when a profit or loss in a gauge is notified.
    event GaugePnL(address indexed gauge, int256 pnl);

    /// @notice emitted when surplus buffer is updated.
    event SurplusBufferUpdate(uint256 newValue);

    /// @notice emitted when CCIP multiplier is updated.
    event CCIPMultiplierUpdate(uint256 newValue);

    /// @notice emitted when profit sharing is updated.
    event ProfitSharingConfigUpdate(
        uint256 surplusBufferSplit,
        uint256 gTokenSplit
    );

    /// @notice emitted when a gToken member claims their CCIP rewards.
    event ClaimRewards(
        address indexed user,
        address indexed gauge,
        uint256 amount
    );

    /// @notice emitted when minBorrow is updated
    event MinBorrowUpdate(uint256 newValue);

    /// @notice emitted when maxTotalIssuance is updated
    event MaxTotalIssuanceUpdate(uint256 newValue);

    /**
     * @notice Storage
    */

    /// @notice internal structure used to optimize storage read, public functions use
    /// uint256 numbers with 18 decimals.
    /// @dev the variables should be with 9 decimals.
    /// @param surplusBufferSplit percentage of profits that go to the surplus buffer
    /// @param gTokenSplit percentage of profits that go to gTokens holders
    struct ProfitSharingConfig {
        uint32 surplusBufferSplit; 
        uint32 gTokenSplit; 
    }

    /// @notice configuration of profit sharing.
    /// `surplusBufferSplit`, `gTokenSplit`, are expressed as percentages with 9 decimals,
    /// so a value of 1e9 would direct 100% of profits. The sum should be <= 1e9.
    ProfitSharingConfig internal profitSharingConfig;

    /// @notice profit index of a given gauge
    mapping(address => uint256) public gaugeProfitIndex;

    /// @notice profit index of a given user in a given gauge
    mapping(address => mapping(address => uint256)) public userGaugeProfitIndex;

    /// @notice amount of first-loss capital in the system.
    /// This is a number of CCIP token held on this contract that can be used to absorb losses in
    /// cases where a loss is reported through `notifyPnL`. The surplus buffer is depleted first, and
    /// if the loss is greater than the surplus buffer, the `ccipTokenValue` is updated down.
    uint256 public surplusBuffer;

    /// @notice multiplier for CCIP token in the system.
    /// The CCIP multiplier can only go down (CCIP can only lose value over time, when bad debt
    /// is created in the system).
    uint256 public ccipTokenValue = 1e18;

    /// @notice minimum size of CCIP loans.
    /// @dev This value is adjusted up when the ccipTokenValue goes down.
    uint256 internal _minBorrow = 0.01e18;

    /// @notice total amount of CCIP tokens issued in pools of this market.
    /// Should be equal to the sum of all Pool.issuance().
    uint256 public totalIssuance;

    /// @notice Reference value for total supply, does not represent the actual token supply.
    uint256 CCIP_TOTAL_SUPPLY = 100e18;

    /// @notice maximum total amount of CCIP allowed to be issued in this market.
    /// This value is adjusted up when the ccipTokenValue goes down.
    /// This is set to a very large value by default to not restrict usage by default.
    uint256 public _maxTotalIssuance = 1e30;

    /// @notice reference to the governance token.
    address public gToken;

    /**
     * @notice Storage - CCIP
    */

    IERC20 public linkToken;
    IRouterClient public router;
    address public ccipToken;

    constructor(
        address _gToken,
        address _router,
        address _linkToken,
        address _ccipToken
    )  {
        gToken = _gToken;
        router = IRouterClient(_router);
        linkToken = IERC20(_linkToken);
        ccipToken = _ccipToken;
        emit MinBorrowUpdate(100e18);
    }

    /**
     * @notice External Functions
    */ 

    /// @notice notify profit and loss in a given gauge
    /// @dev if `amount` is > 0, the same number of CCIP tokens are expected to be transferred to this contract
    /// before `notifyPnL` is called.
    /// @param gauge address of the pool
    /// @param amount profit or loss in CCIP tokens
    /// @param issuanceDelta change in total issuance
    function notifyPnL(
        address gauge,
        int256 amount,
        int256 issuanceDelta
    ) external {
        require(Pool(msg.sender).profitManager() == address(this), "NOT ALLOWED");

        uint256 _surplusBuffer = surplusBuffer;

        totalIssuance = uint256(int256(totalIssuance) + issuanceDelta);

        // check the maximum total issuance if the issuance is changing
        if (issuanceDelta > 0) {
            uint256 __maxTotalIssuance = (_maxTotalIssuance * 1e18) / ccipTokenValue;
            require(totalIssuance <= __maxTotalIssuance, "Global debt ceiling reached");
        }

        // handling loss
        if (amount < 0) {
            // notify loss
            uint256 loss = uint256(-amount);
            GovernanceToken(gToken).notifyGaugeLoss(gauge);

            // deplete the surplus buffer
            if (loss < _surplusBuffer) {
                surplusBuffer = _surplusBuffer - loss;

                // simulates burn loan principal
                IERC20(ccipToken).approve(address(this), loss);
                IERC20(ccipToken).safeTransferFrom(address(this), address(1), loss);

                emit SurplusBufferUpdate( _surplusBuffer - loss);
             
            } else {
                // empty the surplus buffer
                loss -= _surplusBuffer;
                surplusBuffer = 0;

                // simulates burn 
                IERC20(ccipToken).approve(address(this), _surplusBuffer);
                IERC20(ccipToken).safeTransferFrom(address(this), address(1), _surplusBuffer);
                
                emit SurplusBufferUpdate(0);

                // update the CCIP multiplier
                uint256 _CCIP_TOTAL_SUPPLY = CCIP_TOTAL_SUPPLY;
                uint256 newccipTokenValue = 0;
                if (loss < _CCIP_TOTAL_SUPPLY) {
                    newccipTokenValue = (ccipTokenValue * (_CCIP_TOTAL_SUPPLY - loss)) / _CCIP_TOTAL_SUPPLY;
                }

                ccipTokenValue = newccipTokenValue;

                emit CCIPMultiplierUpdate(newccipTokenValue);
            }
        }

        // handling profit
        else if (amount > 0) {
            ProfitSharingConfig memory _profitSharingConfig = profitSharingConfig;

            uint256 amountForSurplusBuffer = (uint256(amount) * uint256(_profitSharingConfig.surplusBufferSplit)) / 1e9;
            uint256 amountForHolders = (uint256(amount) * uint256(_profitSharingConfig.gTokenSplit)) / 1e9;

            // distribute to surplus buffer
            if (amountForSurplusBuffer != 0) {
                surplusBuffer = _surplusBuffer + amountForSurplusBuffer;
                emit SurplusBufferUpdate(_surplusBuffer + amountForSurplusBuffer);
            }
  
            // distribute to the holders
            if (amountForHolders != 0) {
                // if the gauge has 0 weight, does not update the profit index, this is unnecessary
                // because the profit index is used to reattribute profit to users voting for the gauge,
                // and if the weigth is 0, there are no users voting for the gauge.
                uint256 _gaugeWeight = uint256(GovernanceToken(gToken).getGaugeWeight(gauge));
                if (_gaugeWeight != 0) {
                    uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
                    gaugeProfitIndex[gauge] = _gaugeProfitIndex + (amountForHolders * 1e18) / _gaugeWeight;
                }
            }
        }

        emit GaugePnL(gauge, amount);
    }

    /// @notice claim rewards for a given user in a given pool.
    /// @param user address of the user
    /// @param pool address of the pool
    /// @param chainSelector chain selector where rewards goes.
    function claimRewards(address user, address pool, uint64 chainSelector) external returns (uint256 rewards){
        uint256 _rewards = claimGaugeRewards(user, pool);

        if(_rewards != 0) {
            if(chainSelector == 0) {
                IERC20(ccipToken).approve(address(this), _rewards);
                IERC20(ccipToken).safeTransferFrom(address(this), user, _rewards);
            } else {
                // sends the CCIP token
                Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
                    user,
                    ccipToken,
                    _rewards,
                    address(linkToken)
                );

                uint256 fees = router.getFee(
                    chainSelector,
                    evm2AnyMessage
                );

                require(fees <= linkToken.balanceOf(address(this)), "Not enough LINK to pay fees");

                // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
                linkToken.approve(address(router), fees);

                // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
                IERC20(ccipToken).approve(address(router), _rewards);

                // Send the message through the router and store the returned message ID
                router.ccipSend(chainSelector, evm2AnyMessage);
            }

            rewards = _rewards;
        }
    }

    /**
     * @notice Internal Functions
    */

    /// @notice claim a user's rewards for a given gauge.
    /// @dev This should be called every time the user's weight changes in the gauge.
    /// @param user address of the user
    /// @param gauge address of the pool
    function claimGaugeRewards(
        address user,
        address gauge
    ) internal returns (uint256 ccipEarned) {
        uint256 _userGaugeWeight = uint256(GovernanceToken(gToken).getUserGaugeWeight(user, gauge));
        uint256 _userGaugeProfitIndex = userGaugeProfitIndex[user][gauge];
  
        uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
        if (_gaugeProfitIndex == 0) {
            _gaugeProfitIndex = 1e18;
        }

        userGaugeProfitIndex[user][gauge] = _gaugeProfitIndex;
        if (_userGaugeWeight == 0) {
            return 0;
        }

        uint256 deltaIndex = _gaugeProfitIndex - _userGaugeProfitIndex; 
        if (deltaIndex != 0) {
            ccipEarned = (_userGaugeWeight * deltaIndex) / 1e18;
            emit ClaimRewards(user, gauge, ccipEarned);
        }
    }

    /**
     * @notice Owner Setter
    */

    /// @notice set the maximum total issuance
    function setMaxTotalIssuance(
        uint256 newValue
    ) external onlyOwner {
        _maxTotalIssuance = newValue;
        emit MaxTotalIssuanceUpdate(newValue);
    }

    /// @notice set the profit sharing config.
    function setProfitSharingConfig(
        uint256 surplusBufferSplit,
        uint256 gTokenSplit
    ) external onlyOwner {
        require(surplusBufferSplit  + gTokenSplit  == 1e18, "Invalid config");

        profitSharingConfig = ProfitSharingConfig({
            surplusBufferSplit: uint32(surplusBufferSplit / 1e9),
            gTokenSplit: uint32(gTokenSplit / 1e9)
        });

        emit ProfitSharingConfigUpdate(
            surplusBufferSplit,
            gTokenSplit
        );
    }

    /// @notice set the minimum borrow amount
    function setMinBorrow(
        uint256 newValue
    ) external onlyOwner {
        _minBorrow = newValue;
        emit MinBorrowUpdate(newValue);
    }

    /**
     * @notice View Functions
    */

    /// @notice read & return pending undistributed rewards for a given user
    function getPendingRewards(
        address user
    )
        external
        view
        returns (
            address[] memory gauges,
            uint256[] memory creditEarned,
            uint256 totalCreditEarned
        )
    {
        address _gToken = gToken;
        gauges = GovernanceToken(_gToken).userGauges(user);
        creditEarned = new uint256[](gauges.length);

        for (uint256 i = 0; i < gauges.length; ) {
            address gauge = gauges[i];
            uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
            uint256 _userGaugeProfitIndex = userGaugeProfitIndex[user][gauge];

            if (_gaugeProfitIndex == 0) {
                _gaugeProfitIndex = 1e18;
            }

            uint256 deltaIndex = _gaugeProfitIndex - _userGaugeProfitIndex;
            if (deltaIndex != 0) {
                uint256 _userGaugeWeight = uint256(
                    GovernanceToken(_gToken).getUserGaugeWeight(user, gauge)
                );
                creditEarned[i] = (_userGaugeWeight * deltaIndex) / 1e18;
                totalCreditEarned += creditEarned[i];
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice get the profit sharing config.
    function getProfitSharingConfig()
        external
        view
        returns (
            uint256 surplusBufferSplit,
            uint256 gTokenSplit
        )
    {
        surplusBufferSplit =  uint256(profitSharingConfig.surplusBufferSplit) * 1e9;
        gTokenSplit = uint256(profitSharingConfig.gTokenSplit) * 1e9;
    }

    /// @notice get the minimum borrow amount
    function minBorrow() external view returns (uint256) {
        return (_minBorrow * 1e18) / ccipTokenValue;
    }

    /// @notice get the maximum total issuance
    function maxTotalIssuance() external view returns (uint256) {
        return (_maxTotalIssuance * 1e18) / ccipTokenValue;
    }

    /**
     * @notice CCIP sender function
    */

    function _buildCCIPMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver), // ABI-encoded receiver address
                data: "", // No data
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 0})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }
}