// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";

import {ProfitManager} from "../network/ProfitManager.sol";
import {AuctionManager} from "../network/AuctionManager.sol";
import {GovernanceToken} from "../tokens/GovernanceToken.sol";
import {PoolReceiver} from "./PoolReceiver.sol";

contract Pool is OwnerIsCreator {
    using SafeERC20 for IERC20;

    /**
     * @notice Events
    */

    /// @notice emitted when new loans are opened (mint debt to borrower, pull collateral from borrower).
    event LoanOpen(
        bytes32 loanId,
        address indexed borrower,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint64 chainSelector
    );

    /// @notice emitted when a loan is called.
    event LoanCall(bytes32 indexed loanId);

    /// @notice emitted when a loan is closed.
    event LoanClose(
        bytes32 indexed loanId,
        uint256 debtRepaid
    );

    /// @notice emitted when someone adds collateral to a loan.
    event LoanAddCollateral(
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 collateralAmount
    );

    /**
     * @notice Storage
    */

    /// @notice Created when a borrow is created.
    /// @param borrower address of the borrower.
    /// @param borrowTime the time the loan was initiated.
    /// @param borrowAmount initial CCIP token of a loan.
    /// @param borrowCCIPTokenValue ccipTokenValue when loan was opened.
    /// @param collateralAmount balance of collateral token provided by the borrower.
    /// @param caller caller of 0 indicates that the loan has not been called.
    /// @param callTime the time the loan was called.
    /// @param closeTime the time the loan was closed.
    /// @param callDebt the CCIP debt when the loan was called.
    struct Loan {
        address borrower; 
        uint48 borrowTime; 
        uint256 borrowAmount; 
        uint256 borrowCCIPTokenValue; 
        uint256 collateralAmount; 
        address caller; 
        uint48 callTime; 
        uint48 closeTime; 
        uint256 callDebt; 
    }
    
    /// @notice the list of all loans that existed or are still active.
    /// @dev see public getLoan(loanId) getter.
    mapping(bytes32 => Loan) public loans;

    /// @notice Reference number of seconds per periods in which the interestRate is expressed. This is equal to 365.25 days.
    uint256 public constant YEAR = 31557600;

    /// @notice reference to the collateral token
    address public collateralToken;

    /// @notice reference to the PoolReceiver contract created in this pool.
    PoolReceiver public poolReceiver;

    /// @notice reference to the profitManager
    address public profitManager;

    /// @notice reference to the auctionManager
    address public auctionManager;

    /// @notice reference to the governance token
    address public gToken;

    /// @notice max number of debt tokens issued per collateral token.
    uint256 public maxDebtPerCollateralToken;

    /// @notice interest rate paid by the borrower, expressed as an APR
    /// with 18 decimals (0.01e18 = 1% APR). The base for 1 year is the YEAR constant.
    uint256 public interestRate;

    /// @notice current number of ccip issued in active loans on this pool
    uint256 public issuance;

    /// @notice the opening fee is a percent of interest that instantly accrues
    /// when the loan is opened.
    /// The opening fee is expressed as a percentage of the borrowAmount, with 18
    /// decimals, e.g. 0.05e18 = 5% of the borrowed amount.
    /// A loan with 2% openingFee and 3% interestRate will owe 102% of the borrowed
    /// amount just after being open, and after 1 year will owe 105%.
    uint256 openingFee;

    /**
     * @notice Storage - CCIP
    */

    IERC20 public linkToken;
    IRouterClient public router;
    address public ccipToken;

    constructor(
        address _collateralToken,
        address _profitManager,
        address _gToken,
        address _router,
        address _link,
        address _ccipToken,
        address _auctionManager,
        uint256 _interestRate,
        uint256 _maxDebtPerCollateral,
        uint256 _openingFee
    ) {
        linkToken = IERC20(_link);
        router = IRouterClient(_router);
        ccipToken = _ccipToken;
        collateralToken = _collateralToken;
        profitManager = _profitManager;
        gToken = _gToken;
        auctionManager = _auctionManager;
        maxDebtPerCollateralToken = _maxDebtPerCollateral;
        interestRate = _interestRate;
        openingFee = _openingFee;

        poolReceiver = new PoolReceiver(
            _router,
            address(this),
            _ccipToken,
            _profitManager
        );

        GovernanceToken(gToken).addGauge(address(this));
    }

    /**
     * @notice External Functions
    */

    /// @notice initiate a new loan
    /// @param collateralAmount amount of collateral token provided by the borrower.
    /// @param borrowAmount amount of CCIP token borrowed.
    /// @param chainSelector the destination chain of the loan.
    function borrow(
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint64 chainSelector
    ) external  returns(bytes32 loanId){
        require(borrowAmount != 0, "Invalid borrow amount");
        require(collateralAmount != 0, "Invalid collateral amount");

        loanId = keccak256(abi.encode(msg.sender, address(this), block.timestamp));
        require(loans[loanId].borrowTime == 0, "Loan already exists");

        // check that enough collateral is provided
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        uint256 maxBorrow = _maxDebtForCollateral(collateralAmount, ccipTokenValue);
        require(borrowAmount <= maxBorrow, "Not enough collateral");
        require(borrowAmount >= ProfitManager(profitManager).minBorrow(), "Borrow amount too low");
   
        uint256 _issuance = issuance;

        // check that the debt ceiling is not reached
        uint256 _debtCeiling = maxBorrowableAmount();
        uint256 _postBorrowIssuance = _issuance + borrowAmount;
        require(_postBorrowIssuance <= _debtCeiling, "Debt ceiling reached");

        // save loan in state
        loans[loanId] = Loan({
            borrower: msg.sender,
            borrowTime: uint48(block.timestamp),
            borrowAmount: borrowAmount,
            borrowCCIPTokenValue: ccipTokenValue,
            collateralAmount: collateralAmount,
            caller: address(0),
            callTime: 0,
            closeTime: 0,
            callDebt: 0
        });

        // notify ProfitManager of issuance change
        ProfitManager(profitManager).notifyPnL(address(this), 0, int256(borrowAmount));

        issuance = _postBorrowIssuance;

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // sends the CCIP token
        if(chainSelector == 0) {
            IERC20(ccipToken).approve(address(this), borrowAmount);
            IERC20(ccipToken).safeTransferFrom(address(this), msg.sender, borrowAmount);
        } else {
            Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
                msg.sender,
                ccipToken,
                borrowAmount,
                address(linkToken)
            );

            uint256 fees = router.getFee(chainSelector, evm2AnyMessage);
            require(fees <= linkToken.balanceOf(address(this)), "Not enough LINK to pay fees");

            // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
            linkToken.approve(address(router), fees);

            // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
            IERC20(ccipToken).approve(address(router), borrowAmount);

            // Send the message through the router and store the returned message ID
            router.ccipSend(chainSelector, evm2AnyMessage);
        }

        emit LoanOpen(
            loanId,
            msg.sender,
            collateralAmount,
            borrowAmount,
            chainSelector
        );
    }

    /// @notice add collateral on an open loan.
    /// @param loanId unique id of the loan.
    /// @param collateralToAdd amount of collateral token to add.
    function addCollateral(
        bytes32 loanId,
        uint256 collateralToAdd
    ) external {
        require(collateralToAdd != 0, "Invalid collateral amount");

        Loan storage loan = loans[loanId];

        require(loan.callTime == 0, "Loan called");
        require(loan.borrowTime != 0, "Loan does not exist");
        require(loan.closeTime == 0, "Loan closed");

        // update loan in state
        loan.collateralAmount += collateralToAdd;

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralToAdd);

        emit LoanAddCollateral(
            loanId,
            msg.sender,
            collateralToAdd
        );
    }
 
    /// @notice repay an open loan
    /// @param loanId unique id of the loan.
    /// @param loanDebt amount of CCIP token to repay.
    /// @param isCrossChain true if the repayment is cross-chain.
    function repay(
        bytes32 loanId,
        uint256 loanDebt,
        bool isCrossChain 
    ) external {
        Loan storage loan = loans[loanId];
        require(loans[loanId].borrowTime < block.timestamp, "Loan opened in same block");

        uint256 _loanDebt = getLoanDebt(loanId);
        require(_loanDebt == loanDebt, "Invalid amount");

        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        uint256 borrowAmount = loan.borrowAmount;
        uint256 principal = (borrowAmount * loan.borrowCCIPTokenValue) / ccipTokenValue;
        uint256 interest = loanDebt - principal;

        if(!isCrossChain) {
            IERC20(ccipToken).approve(address(this), loanDebt);
            IERC20(ccipToken).safeTransferFrom(msg.sender, address(this), loanDebt);
        }

        /// transfer the ccip to the profit manager.
        if (interest != 0) {
            // forward profit portion to the ProfitManager
            IERC20(ccipToken).approve(address(this), interest);
            IERC20(ccipToken).safeTransferFrom(address(this), profitManager, interest);

            ProfitManager(profitManager).notifyPnL(address(this), int256(interest), -int256(borrowAmount));
        } 

        // simulates burn 
        IERC20(ccipToken).approve(address(this), principal);
        IERC20(ccipToken).safeTransferFrom(address(this), address(1), principal);

        // close the loan
        loan.closeTime = uint48(block.timestamp);
        issuance -= borrowAmount;

        // return the collateral to the borrower
        IERC20(collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanClose(loanId, loanDebt);
    } 

    /// @notice call a loan, the collateral will be auctioned to repay outstanding debt.
    /// Loans can be called only if the term has been offboarded or if the debt raise too much.
    /// @param loanId unique id of the loan.
    function call(
        bytes32 loanId
    ) external {
        Loan storage loan = loans[loanId];
        uint256 borrowTime = loan.borrowTime;

        require(loan.borrowTime != 0, "Loan not found");
        require(loan.closeTime == 0, "Loan closed");
        require(loan.callTime == 0, "Loan called");

        // check that the loan can be called
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        uint256 _loanDebt = _getLoanDebt(loanId, ccipTokenValue);
        require(
            GovernanceToken(gToken).isDeprecatedGauge(address(this)) || 
            _loanDebt > _maxDebtForCollateral(loans[loanId].collateralAmount, ccipTokenValue), "Cannot call"
        );

        // check that the loan has been running for at least 1 block
        require(borrowTime < block.timestamp, "Loan opened in same block");

        // update loan in state
        loans[loanId].callTime = uint48(block.timestamp);
        loans[loanId].callDebt = _loanDebt;
        loans[loanId].caller = msg.sender;

        // auction the loan collateral
        AuctionManager(auctionManager).startAuction(loanId);

        emit LoanCall(loanId);
    }

    function onBid(
        bytes32 loanId,
        address bidder,
        uint256 collateralToBorrower,
        uint256 collateralToBidder,
        uint256 ccipTokenFromBidder
    ) external {
        require(msg.sender == address(auctionManager));
        require(loans[loanId].callTime != 0 && loans[loanId].callDebt != 0, "Loan not called");
        require(loans[loanId].closeTime == 0, "Loan closed");

        uint256 collateralOut = collateralToBidder + collateralToBorrower; 
        require(
            collateralOut == loans[loanId].collateralAmount ||
            collateralOut == 0,
            "Invalid collateral movements"
        );

        // compute pnl
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        uint256 borrowAmount = loans[loanId].borrowAmount;
        uint256 principal = (borrowAmount * loans[loanId].borrowCCIPTokenValue) / ccipTokenValue;
        int256 pnl;
        uint256 interest;
        if (ccipTokenFromBidder >= principal) {
            interest = ccipTokenFromBidder - principal;
            pnl = int256(interest);
        } else {
            pnl = int256(ccipTokenFromBidder) - int256(principal);
            principal = ccipTokenFromBidder;
            require(
                collateralToBorrower == 0,
                "Invalid collateral movement"
            );
        }

        loans[loanId].closeTime = uint48(block.timestamp);

        if (principal != 0) {
            // simulates burn loan principal
            IERC20(ccipToken).approve(address(this), principal);
            IERC20(ccipToken).safeTransferFrom(address(this), address(1), principal);
        }

        // handle profit & losses
        if (pnl != 0) {
            if (interest != 0) {
                IERC20(ccipToken).approve(address(this), interest);
                IERC20(ccipToken).safeTransferFrom(address(this), profitManager, interest);
            }
            ProfitManager(profitManager).notifyPnL(address(this), pnl, -int256(borrowAmount));
        }

        // decrease issuance
        issuance -= borrowAmount;

        // send collateral to borrower
        if (collateralToBorrower != 0) {
            IERC20(ccipToken).approve(address(this), collateralToBorrower);
            IERC20(collateralToken).transfer(loans[loanId].borrower, collateralToBorrower);
        }
  
        // send collateral to msg.sender
        if (collateralToBidder != 0) {
            IERC20(ccipToken).approve(address(this), collateralToBidder);
            IERC20(collateralToken).transfer(bidder, collateralToBidder);
        }

        emit LoanClose(loanId, ccipTokenFromBidder); 
    }

    /**
     * @notice View Functions
    */

    /// @notice returns the loan debt of a loan given the current ccipTokenValue.
    function _getLoanDebt(
        bytes32 loanId,
        uint256 ccipTokenValue
    ) internal view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 borrowTime = loan.borrowTime;

        if (borrowTime == 0) {
            return 0;
        }

        if (loan.closeTime != 0) {
            return 0;
        }

        if (loan.callTime != 0) {
            return loan.callDebt;
        }

        // compute interest owed
        uint256 borrowAmount = loan.borrowAmount;

        uint256 interest = (borrowAmount * interestRate *
            (block.timestamp - borrowTime)) / YEAR / 1e18;

        uint256 loanDebt = borrowAmount + interest;
        uint256 _openingFee = openingFee;
        if (_openingFee != 0) {
            loanDebt += (borrowAmount * _openingFee) / 1e18;
        }
        loanDebt = (loanDebt * loan.borrowCCIPTokenValue) / ccipTokenValue;

        return loanDebt;
    }

    function maxBorrowableAmount() public view returns (uint256) {
        uint256 actualBalance = IERC20(ccipToken).balanceOf(address(this));
        return actualBalance / 4; // 25% of the total tokens
    }    

    /// @notice get a loan
    function getLoan(bytes32 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /// @notice outstanding borrowed amount of a loan, including interests
    function getLoanDebt(bytes32 loanId) public view returns (uint256) {
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        return _getLoanDebt(loanId, ccipTokenValue);
    }

    /// @notice maximum debt for a given amount of collateral
    function maxDebtForCollateral(
        uint256 collateralAmount
    ) public view returns (uint256) {
        uint256 ccipTokenValue = ProfitManager(profitManager).ccipTokenValue();
        return _maxDebtForCollateral(collateralAmount, ccipTokenValue);
    }

    /// @notice maximum debt for a given amount of collateral & ccipTokenValue
    function _maxDebtForCollateral(
        uint256 collateralAmount,
        uint256 ccipTokenValue
    ) internal view returns (uint256) {
        return
            (collateralAmount * maxDebtPerCollateralToken) / ccipTokenValue;
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