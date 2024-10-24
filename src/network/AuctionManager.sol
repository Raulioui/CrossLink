// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProfitManager} from "./ProfitManager.sol";
import {PoolReceiver} from "../pool/PoolReceiver.sol";
import {Pool} from "../pool/Pool.sol";

/// @notice Contract manager where collateral of borrowers is auctioned to cover their CCIP debt.
contract AuctionManager is CCIPReceiver {
    using SafeERC20 for IERC20;

    /**
     * @notice Events
    */

    /// @notice emitted when an unction start
    /// @param loanId unique id of the loan.
    /// @param collateralToken address of the collateral token.
    /// @param collateralAmount amount of collateral to be auctioned.
    /// @param callDebt amount of debt to be paid.
    event AuctionStart(
        bytes32 indexed loanId,
        address collateralToken,
        uint256 collateralAmount,
        uint256 callDebt
    );

    /// @notice emitted when an auction ends
    /// @param loanId unique id of the loan.
    /// @param collateralToken address of the collateral token.
    /// @param collateralSold amount of collateral sold.
    /// @param debtRecovered amount of debt recovered.
    event AuctionEnd(
        bytes32 indexed loanId,
        address collateralToken,
        uint256 collateralSold,
        uint256 debtRecovered
    );

    /**
     * @notice Storage
    */

    /// @notice Auction struct created when a loan is called.
    /// @param startTime timestamp at which the auction started.
    /// @param endTime timestamp at which the auction ended.
    /// @param pool address of the pool that created the auction.
    /// @param collateralAmount amount of collateral to be auctioned.
    /// @param callDebt amount of debt to be paid.
    /// @param callCCIPTokenValue the value of the CCIP token at the time of the call.
    struct Auction {
        uint48 startTime;
        uint48 endTime;
        address pool;
        uint256 collateralAmount;
        uint256 callDebt;
        uint256 callCCIPTokenValue;
    }

    /// @notice the list of all auctions that existed or are still active.
    /// @dev see public getAuction(loanId) getter.
    mapping(bytes32 => Auction) internal auctions;

    /// @notice number of seconds before the midpoint of the auction, at which time the
    /// mechanism switches from "offer an increasing amount of collateral" to
    /// "ask a decreasing amount of debt".
    uint256 public immutable midPoint;

    /// @notice maximum duration of auctions, in seconds.
    uint256 public immutable auctionDuration;

    /// @notice starting percentage of collateral offered, expressed as a percentage with 18 decimals.
    uint256 public immutable startCollateralOffered;

    /// @notice number of auctions currently in progress
    uint256 public auctionsInProgress;

    /// @notice address of the profit manager
    address public profitManager;

    /// @notice address of the CCIP token
    address public ccipToken;

    constructor(
        uint256 _midPoint,
        uint256 _auctionDuration,
        uint256 _startCollateralOffered,
        address _router,
        address _profitManager,
        address _ccipToken
    ) CCIPReceiver(_router) {
        require(_midPoint < _auctionDuration, "Invalid params");
        midPoint = _midPoint;
        auctionDuration = _auctionDuration;
        startCollateralOffered = _startCollateralOffered;
        profitManager = _profitManager;
        ccipToken = _ccipToken;
    }   

    /**
     * @notice External Functions
    */

    /// @notice start the auction of the collateral of a loan, to be exchanged for CCIP,
    /// in order to pay the debt of a loan.
    /// @param loanId unique id of the loan.
    function startAuction(bytes32 loanId) external {
        require(Pool(msg.sender).auctionManager() == address(this), "NOT ALLOWED");
        Pool.Loan memory loan = Pool(msg.sender).getLoan(loanId);

        require(loan.callTime == block.timestamp, "Loan previously called");
        require(auctions[loanId].startTime == 0, "Auction exists");

        // create the auction in state
        auctions[loanId] = Auction({
            startTime: uint48(block.timestamp),
            endTime: 0,
            pool: msg.sender,
            collateralAmount: loan.collateralAmount,
            callDebt: loan.callDebt,
            callCCIPTokenValue: ProfitManager(
                Pool(msg.sender).profitManager()
            ).ccipTokenValue()
        });

        auctionsInProgress++;

        emit AuctionStart(
            loanId,
            Pool(msg.sender).collateralToken(),
            loan.collateralAmount,
            loan.callDebt
        );
    }

    /// @notice bid for an active auction
    /// @param loanId unique id of the loan.
    /// @param collateralToBidder amount of collateral received.
    /// @param ccipTokenFromBidder amount of CCIP token from the bidder.
    function bid(bytes32 loanId, uint256 collateralToBidder, uint256 ccipTokenFromBidder, bool isCrossChain) public {
        require(ccipTokenFromBidder != 0, "Cannot bid 0");

        auctions[loanId].endTime = uint48(block.timestamp);
        auctionsInProgress--;

        address pool = auctions[loanId].pool;

        if(!isCrossChain) {
            IERC20(ccipToken).safeTransferFrom(msg.sender, address(this), ccipTokenFromBidder);
        }

        Pool(pool).onBid(
            loanId,
            msg.sender,
            auctions[loanId].collateralAmount - collateralToBidder,
            collateralToBidder, 
            ccipTokenFromBidder 
        );

        // emit event
        emit AuctionEnd(
            loanId,
            Pool(pool).collateralToken(),
            collateralToBidder, 
            ccipTokenFromBidder 
        );
    }

    /**
     * @notice CCIP
    */

    /// @notice Entry point for bid for an auction from another chain
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        bytes32 loanId = abi.decode(any2EvmMessage.data, (bytes32));
        address pool = auctions[loanId].pool;
        address token = any2EvmMessage.destTokenAmounts[0].token;
        require(token == PoolReceiver(address(Pool(pool).poolReceiver())).ccipToken(), "Invalid token");

        (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = getBidDetail(loanId);  
    
        bid(loanId, collateralToBidder, ccipTokenFromBidder, true);
    }

    /**
     * @notice View Functions
    */

    /// @notice get the details of a bid for an active auction
    /// @param loanId unique id of the loan.
    function getBidDetail(
        bytes32 loanId
    ) public view returns (uint256 collateralToBidder, uint256 ccipTokenFromBidder) {
        uint256 _startTime = auctions[loanId].startTime;
        require(_startTime != 0, "Invalid auction");
        require(auctions[loanId].endTime == 0, "Auction ended");
        assert(block.timestamp >= _startTime);

        if (block.timestamp < _startTime + midPoint) {
            // ask for the full debt
            ccipTokenFromBidder = auctions[loanId].callDebt;

            // compute amount of collateral received
            uint256 elapsed = block.timestamp - _startTime; // [0, midPoint[
            uint256 _collateralAmount = auctions[loanId].collateralAmount; 
            uint256 mincollateralToBidder = (startCollateralOffered * _collateralAmount) / 1e18;
            uint256 remainingCollateral = _collateralAmount - mincollateralToBidder;
            collateralToBidder = mincollateralToBidder + (remainingCollateral * elapsed) / midPoint;
        }

        // second phase of the auction, where less and less ccip token is asked
        else if (block.timestamp < _startTime + auctionDuration) {
            // receive the full collateral
            collateralToBidder = auctions[loanId].collateralAmount;

            // compute amount of ccip token to ask
            uint256 PHASE_2_DURATION = auctionDuration - midPoint;
            uint256 elapsed = block.timestamp - _startTime - midPoint; // [0, PHASE_2_DURATION[
            uint256 _callDebt = auctions[loanId].callDebt; // SLOAD
            ccipTokenFromBidder = _callDebt - (_callDebt * elapsed) / PHASE_2_DURATION;
        }
        // second phase fully elapsed, anyone can receive the full collateral and give 0 ccip token
        // in practice, somebody should have taken the arb before we reach this condition
        else {
            // receive the full collateral
            collateralToBidder = auctions[loanId].collateralAmount;
        }

        // apply eventual ccipTokenValue updates
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        ccipTokenFromBidder = (ccipTokenFromBidder * auctions[loanId].callCCIPTokenValue) / ccipTokenValue;
    }

    /// @notice get a full auction structure from storage
    function getAuction(bytes32 loanId) external view returns (Auction memory) {
        return auctions[loanId];
    }
}