// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/** 
@title  An ERC20 with an embedded "Gauge" style vote with liquid weights
@notice This contract was originally published as part of TribeDAO's flywheel-v2 repo, please see:
        https://github.com/fei-protocol/flywheel-v2/blob/main/src/token/ERC20Gauges.sol
*/
abstract contract ERC20Gauges is ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @notice Events
    */

    /// @notice emitted when incrementing a gauge
    event IncrementGaugeWeight(
        address indexed user,
        address indexed gauge,
        uint256 weight
    );

    /// @notice emitted when decrementing a gauge
    event DecrementGaugeWeight(
        address indexed user,
        address indexed gauge,
        uint256 weight
    );

    /// @notice emitted when adding a new gauge to the live set.
    event AddGauge(address indexed gauge);

    /// @notice emitted when removing a gauge from the live set.
    event RemoveGauge(address indexed gauge);

    /// @notice emitted when updating the max number of gauges a user can delegate to.
    event MaxGaugesUpdate(uint256 oldMaxGauges, uint256 newMaxGauges);

    /// @notice emitted when changing a contract's approval to go over the max gauges.
    event CanExceedMaxGaugesUpdate(
        address indexed account,
        bool canExceedMaxGauges
    );

    /**
     * @notice Storage
    */

    /// @notice a mapping from users to gauges to a user's allocated weight to that gauge
    mapping(address => mapping(address => uint256)) public getUserGaugeWeight;

    /// @notice a mapping from a user to their total allocated weight across all gauges
    /// @dev NOTE this may contain weights for deprecated gauges
    mapping(address => uint256) public getUserWeight;

    /// @notice a mapping from a gauge to the total weight allocated to it
    /// @dev NOTE this may contain weights for deprecated gauges
    mapping(address => uint256) public getGaugeWeight;

    /// @notice the total global allocated weight ONLY of live gauges
    uint256 public totalWeight;

    mapping(address => EnumerableSet.AddressSet) internal _userGauges;

    EnumerableSet.AddressSet internal _gauges;

    // Store deprecated gauges in case a user needs to free dead weight
    EnumerableSet.AddressSet internal _deprecatedGauges;

    /// @notice the default maximum amount of gauges a user can allocate to.
    uint256 public maxGauges;

    /// @notice an approve list for contracts to go above the max gauge limit.
    mapping(address => bool) public canExceedMaxGauges;

    /// @dev this function does not check if the gauge exists, this is performed
    /// in the calling function.
    function _incrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal virtual {
        require(isGauge(gauge), "Invalid gauge");

        bool added = _userGauges[user].add(gauge);
        if (added && _userGauges[user].length() > maxGauges) {
            require(canExceedMaxGauges[user], "Max gauges exceeded");
        }

        getUserGaugeWeight[user][gauge] += weight;

        getGaugeWeight[gauge] += weight;

        getUserWeight[user] += weight;

        totalWeight += weight;

        emit IncrementGaugeWeight(user, gauge, weight);
    }

    /** 
     @notice decrement a gauge with some weight for the caller
     @param gauge the gauge to decrement
     @param weight the amount of weight to decrement on gauge
     @return newUserWeight the new user weight
    */
    function decrementGauge(
        address gauge,
        uint256 weight,
        address user
    ) public virtual returns (uint256 newUserWeight) {
        require(msg.sender == address(this), "NOT ALLOWED");
        // All operations will revert on underflow, protecting against bad inputs
        _decrementGaugeWeight(user, gauge, weight);
        if (!_deprecatedGauges.contains(gauge)) {
            totalWeight -= weight;
        }
        return getUserWeight[user];
    }

    function _decrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal virtual {
        uint256 oldWeight = getUserGaugeWeight[user][gauge];

        getUserGaugeWeight[user][gauge] = oldWeight - weight;
        if (oldWeight == weight) {
            require(_userGauges[user].remove(gauge));
        }

        getGaugeWeight[gauge] -= weight;
        getUserWeight[user] -= weight;

        emit DecrementGaugeWeight(user, gauge, weight);
    }

    function _addGauge(
        address gauge
    ) internal returns (uint256 weight) {
        bool newAdd = _gauges.add(gauge);
        bool previouslyDeprecated = _deprecatedGauges.remove(gauge);
        // add and fail loud if zero address or already present and not deprecated
        require(gauge != address(0) && (newAdd || previouslyDeprecated), "Invalid gauge");

        // Check if some previous weight exists and re-add to total. Gauge and user weights are preserved.
        weight = getGaugeWeight[gauge];
        if (weight != 0) {
            totalWeight += weight;
        }

        emit AddGauge(gauge);
    }

    function _removeGauge(address gauge) internal {
        // add to deprecated and fail loud if not present
        require(_gauges.contains(gauge) && _deprecatedGauges.add(gauge), "Invalid gauge");

        // Remove weight from total but keep the gauge and user weights in storage in case gauge is re-added.
        uint256 weight = getGaugeWeight[gauge];
        if (weight != 0) {
            totalWeight -= weight;
        }

        emit RemoveGauge(gauge);
    }

    /// @notice set the new max gauges. Requires auth by `authority`.
    /// @dev if this is set to a lower number than the current max, users MAY have more gauges active than the max. Use `numUserGauges` to check this.
    function _setMaxGauges(uint256 newMax) internal {
        uint256 oldMax = maxGauges;
        maxGauges = newMax;

        emit MaxGaugesUpdate(oldMax, newMax);
    }

    /// @notice set the canExceedMaxGauges flag for an account.
    function _setCanExceedMaxGauges(
        address account,
        bool canExceedMax
    ) internal {
        if (canExceedMax) {
            require(account.code.length != 0, "Not a smart contract");
        }

        canExceedMaxGauges[account] = canExceedMax;
        emit CanExceedMaxGaugesUpdate(account, canExceedMax);
    }

    /**
     * @notice ERC20 functions
    */

    function _burn(address from, uint256 amount) internal virtual override {
        _decrementWeightUntilFree(from, amount);
        super._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementWeightUntilFree(msg.sender, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementWeightUntilFree(from, amount);
        return super.transferFrom(from, to, amount);
    }

    /// a greedy algorithm for freeing weight before a token burn/transfer
    /// frees up entire gauges, so likely will free more than `weight`
    function _decrementWeightUntilFree(address user, uint256 weight) internal {
        uint256 userFreeWeight = balanceOf(user) - getUserWeight[user];

        // early return if already free
        if (userFreeWeight >= weight) return;

        // cache totals for batch updates
        uint256 userFreed;
        uint256 totalFreed;

        // Loop through all user gauges, live and deprecated
        address[] memory gaugeList = _userGauges[user].values();

        // Free gauges until through entire list or under weight
        uint256 size = gaugeList.length;
        for (
            uint256 i = 0;
            i < size && (userFreeWeight + userFreed) < weight;

        ) {
            address gauge = gaugeList[i];
            uint256 userGaugeWeight = getUserGaugeWeight[user][gauge];
            if (userGaugeWeight != 0) {
                userFreed += userGaugeWeight;
                _decrementGaugeWeight(user, gauge, userGaugeWeight);

                // If the gauge is live (not deprecated), include its weight in the total to remove
                if (!_deprecatedGauges.contains(gauge)) {
                    totalFreed += userGaugeWeight;
                }
            }
            unchecked {
                ++i;
            }
        }

        totalWeight -= totalFreed;
    }

    /**
     * @notice View functions
    */

    /// @notice returns the set of live + deprecated gauges
    function gauges() external view returns (address[] memory) {
        return _gauges.values();
    }

    /// @notice returns true if `gauge` is not in deprecated gauges
    function isGauge(address gauge) public view returns (bool) {
        return _gauges.contains(gauge) && !_deprecatedGauges.contains(gauge);
    }

    /// @notice returns true if `gauge` is in deprecated gauges
    function isDeprecatedGauge(address gauge) public view returns (bool) {
        return _deprecatedGauges.contains(gauge);
    }

    /// @notice returns the number of live + deprecated gauges
    function numGauges() external view returns (uint256) {
        return _gauges.length();
    }

    /// @notice returns the set of previously live but now deprecated gauges
    function deprecatedGauges() external view returns (address[] memory) {
        return _deprecatedGauges.values();
    }

    /// @notice returns the number of deprecated gauges
    function numDeprecatedGauges() external view returns (uint256) {
        return _deprecatedGauges.length();
    }

    /// @notice returns the set of currently live gauges
    function liveGauges() external view returns (address[] memory _liveGauges) {
        _liveGauges = new address[](
            _gauges.length() - _deprecatedGauges.length()
        );
        address[] memory allGauges = _gauges.values();
        uint256 j;
        for (uint256 i; i < allGauges.length && j < _liveGauges.length; ) {
            if (!_deprecatedGauges.contains(allGauges[i])) {
                _liveGauges[j] = allGauges[i];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        return _liveGauges;
    }

    /// @notice returns the number of currently live gauges
    function numLiveGauges() external view returns (uint256) {
        return _gauges.length() - _deprecatedGauges.length();
    }

    /// @notice returns the set of gauges the user has allocated to, may be live or deprecated.
    function userGauges(address user) external view returns (address[] memory) {
        return _userGauges[user].values();
    }

    /// @notice returns true if `gauge` is in user gauges
    function isUserGauge(
        address user,
        address gauge
    ) external view returns (bool) {
        return _userGauges[user].contains(gauge);
    }

    /// @notice returns the number of user gauges
    function numUserGauges(address user) external view returns (uint256) {
        return _userGauges[user].length();
    }
}
