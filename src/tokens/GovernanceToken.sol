// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Pool} from "../pool/Pool.sol";
import {ERC20Gauges} from "./ERC20Gauges.sol";
import {ProfitManager} from "../network/ProfitManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";

/// @notice Simple governance token of the system that manages stakings and gauges weights.
contract GovernanceToken is ERC20Burnable, ERC20Gauges, Ownable, CCIPReceiver {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @notice Events
    */

    /// @notice emitted when a loss in a gauge is notified.
    event GaugeLoss(address indexed gauge, uint256 indexed when);
        
    /// @notice emitted when a user stakes on a target pool
    event Stake(
        address indexed pool,
        uint256 amount
    );

    event GaugeLossApply(
        address indexed gauge,
        address indexed who,
        uint256 amount
    );

    /**
     * @notice Storage
    */

    /// @notice UserStake struct created when a user stakes on a pool.
    struct UserStake {
        uint256 stakeTime;
        uint256 profitIndex;
        uint256 ccip;
        uint256 gToken;
    }

    /// @notice list of user stakes (stakes[user][pool]=UserStake)
    mapping(address => mapping(address => UserStake)) internal stakes;

    /// @notice minimum number of CCIP to stake
    uint256 public MIN_STAKE = 0.01e18;

    /// @notice reference to the CCIP token
    address public ccipToken;

    /// @notice last block.timestamp when a loss occurred in a given gauge
    mapping(address => uint256) public lastGaugeLoss;

    /// @notice last block.timestamp when a user apply a loss that occurred in a given gauge
    mapping(address => mapping(address => uint256)) public lastGaugeLossApplied;

    /// @notice ratio of  gTokens minted per CCIP tokens staked.
    /// expressed with 18 decimals, e.g. a ratio of 2e18 would provide 2e18
    /// gTokens to a user that stakes 1e18 CCIP tokens.
    uint256 public mintRatio = 2e18;

    constructor(address _router, address _ccipToken)
        ERC20("GToken", "GToken")
        CCIPReceiver(_router)
    {
        ccipToken = _ccipToken;
    }

    /**
     * @notice External functions
    */

    /// @notice notify loss in a given gauge
    function notifyGaugeLoss(address gauge) external {
        require(_gauges.contains(gauge), "Gauge not found");
        require(msg.sender == Pool(gauge).profitManager(), "UNAUTHORIZED");

        // save gauge loss
        lastGaugeLoss[gauge] = block.timestamp;
        emit GaugeLoss(gauge, block.timestamp);
    }
    
    /// @notice apply a loss that occurred in a given gauge
    /// anyone can apply the loss on behalf of anyone else
    function applyGaugeLoss(address gauge, address who) external {
        // check preconditions
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][who];
        require(
            _lastGaugeLoss != 0 && _lastGaugeLossApplied < _lastGaugeLoss,
            "No loss to apply"
        );

        // read user weight allocated to the lossy gauge
        uint256 _userGaugeWeight = getUserGaugeWeight[who][gauge];

        // remove gauge weight allocation
        lastGaugeLossApplied[gauge][who] = block.timestamp;
        if (!_deprecatedGauges.contains(gauge)) {
            totalWeight -= _userGaugeWeight;
        }
        _decrementGaugeWeight(who, gauge, _userGaugeWeight);
        
        // apply loss
        _burn(who, uint256(_userGaugeWeight));

        emit GaugeLossApply(
            gauge,
            who,
            uint256(_userGaugeWeight)
        );
    }

    function stake(uint256 amount, address staker, address pool, bool isCrossChain) public {
        require(amount >= MIN_STAKE, "Stake amount too low");

        uint256 amountForStake = amount * mintRatio / 1e18;

        if(!isCrossChain) {
            IERC20(ccipToken).approve(address(this), amount);
            IERC20(ccipToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        _incrementGaugeWeight(staker, pool, amount);
        _mint(staker, amountForStake);

        IERC20(ccipToken).approve(address(this), amount);
        IERC20(ccipToken).safeTransferFrom(address(this), pool, amount);

        UserStake memory userStake = UserStake({
            stakeTime: block.timestamp,
            profitIndex: ProfitManager(Pool(pool).profitManager()).userGaugeProfitIndex(staker, pool),
            ccip: amount,
            gToken: amountForStake
        });

        stakes[staker][pool] = userStake;
    }

    function addGauge(
        address gauge
    ) external  returns (uint256) {
        return _addGauge(gauge);
    }

    /**
     * @notice CCIP - Receiver
    */

    /// @notice Entry point of the contract for receive stakes from another chain
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        require(any2EvmMessage.destTokenAmounts[0].token == address(ccipToken), "Invalid token");
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;
        (address pool, address staker) = abi.decode(any2EvmMessage.data, (address, address));

        stake(amount, staker, pool, true);
    }

    /**
     * @notice Implementation of ERC20
    */

    function transfer(
        address to,
        uint256 amount
    )
        public
        virtual
        override(ERC20, ERC20Gauges)
        returns (bool)
    {
        _decrementWeightUntilFree(msg.sender, amount);
        return ERC20.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        virtual
        override(ERC20, ERC20Gauges)
        returns (bool)
    {
        _decrementWeightUntilFree(from, amount);
        return ERC20.transferFrom(from, to, amount);
    }

    /**
     * @notice Internal Functions
    */

    /// @notice mint new tokens to the target address
    function mint(
        address to,
        uint256 amount
    ) internal {
        uint256 amountForStake = amount * mintRatio / 1e18;
        _mint(to, amountForStake);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Gauges) {
        ERC20._burn(from, amount);
    }

    /// @dev prevent weight increment for gauge if user has an unapplied loss.
    /// If the user has 0 weight (i.e. no loss to realize), allow incrementing
    /// gauge weight & update lastGaugeLossApplied to current time.
    /// Also update the user profit index an claim rewards.
    function _incrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        if (getUserGaugeWeight[user][gauge] == 0) {
            lastGaugeLossApplied[gauge][user] = block.timestamp;
        } else {
            require(_lastGaugeLossApplied >= _lastGaugeLoss, "Pending loss");
        }

        super._incrementGaugeWeight(user, gauge, weight);
    }

    /// @dev prevent outbound token transfers (_decrementWeightUntilFree) and gauge weight decrease
    /// (decrementGauge, decrementGauges) for users who have an unrealized loss in a gauge, or if the
    /// gauge is currently using its allocated debt ceiling. To decrement gauge weight, guild holders
    /// might have to call loans if the debt ceiling is used.
    /// Also update the user profit index and claim rewards.
    function _decrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "Pending loss"
        );
        uint256 issuance = Pool(gauge).issuance();
        if (isDeprecatedGauge(gauge)) {
            require(issuance == 0, "Not all loans closed");
        }

        // update the user profit index and claim rewards
        ProfitManager(Pool(gauge).profitManager()).claimRewards(
            user,
            gauge,
            0
        );

        super._decrementGaugeWeight(user, gauge, weight);
    }

    /**
     * @notice Only Owner
    */

    function removeGauge(
        address gauge
    ) external onlyOwner {
        _removeGauge(gauge);
    }

    function setMaxGauges(
        uint256 max
    ) external  onlyOwner {
        _setMaxGauges(max);
    }

    function setCanExceedMaxGauges(
        address who,
        bool can
    ) external onlyOwner {
        _setCanExceedMaxGauges(who, can);
    }


    /**
     * @notice View Functions
    */

    /// @notice get a given user stake
    function getUserStake(
        address user,
        address pool
    ) external view returns (UserStake memory) {
        return stakes[user][pool];
    }
}