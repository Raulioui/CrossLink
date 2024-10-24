// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "lib/chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BurnMintERC677Helper, IERC20} from "lib/chainlink-local/src/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Pool} from "../../../src/pool/Pool.sol";
import {MockERC20} from "../../../mock/ERC20Mock.sol";
import {ProfitManager} from "../../../src/network/ProfitManager.sol";
import {GovernanceToken} from "../../../src/tokens/GovernanceToken.sol";
import {AuctionManager} from "../../../src/network/AuctionManager.sol";
import {PoolReceiver} from "../../../src/pool/PoolReceiver.sol";
import {PersonalAccount} from "../../../src/user/PersonalAccount.sol";

contract TestPool is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    uint256 public sourceFork;
    uint256 public destinationFork;

    address public bob;

    IRouterClient public sourceRouter;
    IRouterClient public destinationRouter;

    uint64 public destinationChainSelector;
    uint64 public sourceChainSelector;

    BurnMintERC677Helper public sourceCCIPBnMToken;
    BurnMintERC677Helper public destinationCCIPBnMToken;

    IERC20 public sourceLinkToken;
    IERC20 public destinationLinkToken;

    Pool public sourcePool;
    Pool public destinationPool;

    MockERC20 public sourceCollateral;
    MockERC20 public destinationCollateral;

    ProfitManager public sourceProfitManager;
    ProfitManager public destinationProfitManager;

    GovernanceToken public sourceToken;
    GovernanceToken public destinationToken;

    AuctionManager public sourceAuctionManager;
    AuctionManager public destinationAuctionManager;

    PersonalAccount public sourceAccount;
    PersonalAccount public destinationAccount;

    uint256 MAX_DEBT_PER_COLLATERAL_TOKEN = 0.01e18;
    uint256 INTEREST_RATE = 0.1e18;
    uint256 OPENING_FEE = 0;

    function setUp() public {
        string memory DESTINATION_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        string memory SOURCE_RPC_URL = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        
        destinationFork = vm.createSelectFork(DESTINATION_RPC_URL);
        sourceFork = vm.createFork(SOURCE_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        vm.selectFork(sourceFork);

        Register.NetworkDetails
            memory sourceNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);
        sourceCCIPBnMToken = BurnMintERC677Helper(sourceNetworkDetails.ccipBnMAddress);
        sourceLinkToken = IERC20(sourceNetworkDetails.linkAddress);
        sourceRouter = IRouterClient(sourceNetworkDetails.routerAddress);
        sourceChainSelector = sourceNetworkDetails.chainSelector;

        sourceToken = new GovernanceToken(
            address(sourceRouter),
            address(sourceCCIPBnMToken)
        );

        sourceProfitManager = new ProfitManager(
            address(sourceToken),
            address(sourceRouter),
            address(sourceLinkToken),
            address(sourceCCIPBnMToken)
        );

        sourceAuctionManager = new AuctionManager(
            650,
            1800,
            0,
            address(sourceRouter),
            address(sourceProfitManager),
            address(sourceCCIPBnMToken)
        );

        sourceCollateral = new MockERC20();

        sourcePool  = new Pool(
            address(sourceCollateral),
            address(sourceProfitManager),
            address(sourceToken),
            address(sourceRouter),
            address(sourceLinkToken),
            address(sourceCCIPBnMToken),
            address(sourceAuctionManager),
            INTEREST_RATE,
            MAX_DEBT_PER_COLLATERAL_TOKEN,
            OPENING_FEE   
        );

        sourceAccount = new PersonalAccount(
            address(sourceLinkToken),
            address(sourceRouter),
            address(sourceCCIPBnMToken)
        );

        sourceToken.setMaxGauges(10);

        vm.selectFork(destinationFork);

        Register.NetworkDetails
            memory destinationNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);
        destinationCCIPBnMToken = BurnMintERC677Helper(destinationNetworkDetails.ccipBnMAddress);
        destinationLinkToken = IERC20(destinationNetworkDetails.linkAddress);
        destinationRouter = IRouterClient(destinationNetworkDetails.routerAddress);

        destinationChainSelector = destinationNetworkDetails.chainSelector;

        destinationToken = new GovernanceToken(
            address(destinationRouter),
            address(destinationCCIPBnMToken)
        );

        destinationProfitManager = new ProfitManager(
            address(destinationToken),
            address(destinationRouter),
            address(destinationLinkToken),
            address(destinationCCIPBnMToken)
        );

        destinationAuctionManager = new AuctionManager(
            650,
            1800,
            0,
            address(destinationRouter),
            address(destinationProfitManager),
            address(destinationCCIPBnMToken)
        );

        destinationCollateral = new MockERC20();

        destinationPool  = new Pool(
            address(destinationCollateral),
            address(destinationProfitManager),
            address(destinationToken),
            address(destinationRouter),
            address(destinationLinkToken),
            address(destinationCCIPBnMToken),
            address(destinationAuctionManager),
            INTEREST_RATE,
            MAX_DEBT_PER_COLLATERAL_TOKEN,
            OPENING_FEE   
        );

        destinationAccount = new PersonalAccount(
            address(destinationLinkToken),
            address(destinationRouter),
            address(destinationCCIPBnMToken)
        );

        destinationToken.setMaxGauges(10);

        vm.selectFork(sourceFork);
    }

    /**
     * @notice Constructor
    */

    function testInitialStatePool() public {
        assertEq(sourcePool.auctionManager(), address(sourceAuctionManager));
        assertEq(sourcePool.collateralToken(), address(sourceCollateral));
        assertEq(sourcePool.gToken(), address(sourceToken));
        assertEq(sourcePool.maxDebtPerCollateralToken(), MAX_DEBT_PER_COLLATERAL_TOKEN);
        assertEq(sourcePool.interestRate(), INTEREST_RATE);

        assertEq(sourcePool.issuance(), 0);
        assertEq(sourcePool.getLoan(bytes32(0)).borrowTime, 0);
        assertEq(sourcePool.getLoanDebt(bytes32(0)), 0);
        assertEq(sourceCollateral.totalSupply(), 0);
    }

    /**
     * @notice Borrow
    */

    function testBorrowAtPoolDifferentNetwork() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
  
        // check loan creation
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount);

        assertEq(sourcePool.getLoan(loanId).borrower, address(this));
        assertEq(sourcePool.getLoan(loanId).borrowTime, block.timestamp);
        assertEq(sourcePool.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(sourcePool.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(sourcePool.getLoan(loanId).caller, address(0));
        assertEq(sourcePool.getLoan(loanId).callTime, 0);
        assertEq(sourcePool.getLoan(loanId).closeTime, 0);

        assertEq(sourcePool.issuance(), borrowAmount);
        assertEq(sourcePool.getLoanDebt(loanId), borrowAmount);

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourcePool)), 1e18 - borrowAmount);

        // check interest accrued over time
        vm.warp(block.timestamp + sourcePool.YEAR());
        assertEq(sourcePool.getLoanDebt(loanId), (borrowAmount * 110) / 100); // 10% APR*/
        
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        assertEq(destinationCCIPBnMToken.balanceOf(address(this)), borrowAmount);
    }

    function testBorrowAtPoolSameNetwork() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);
     
        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, 0);
  
        // check loan creation
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount);

        assertEq(sourcePool.getLoan(loanId).borrower, address(this));
        assertEq(sourcePool.getLoan(loanId).borrowTime, block.timestamp);
        assertEq(sourcePool.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(sourcePool.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(sourcePool.getLoan(loanId).caller, address(0));
        assertEq(sourcePool.getLoan(loanId).callTime, 0);
        assertEq(sourcePool.getLoan(loanId).closeTime, 0);

        assertEq(sourcePool.issuance(), borrowAmount);
        assertEq(sourcePool.getLoanDebt(loanId), borrowAmount);

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourcePool)), 1e18 - borrowAmount);

        // check interest accrued over time
        vm.warp(block.timestamp + sourcePool.YEAR());
        assertEq(sourcePool.getLoanDebt(loanId), (borrowAmount * 110) / 100); // 10% APR*/
        
        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), borrowAmount);
    }

    // borrow fail because 0 collateral
    function testBorrowFailNoCollateral() public {
        uint256 borrowAmount = 1e18;
        uint256 collateralAmount = 0;
        vm.expectRevert("Invalid collateral amount");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    // borrow fail because not enough borrowed
    function testBorrowFailAmountTooSmall() public {
        uint256 borrowAmount = 0.0001e18;
        uint256 collateralAmount = 0.01e18;
        vm.expectRevert("Borrow amount too low");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    // borrow fail because 0 debt
    function testBorrowFailNoDebt() public {
        uint256 borrowAmount = 0;
        uint256 collateralAmount = 1e18;
        vm.expectRevert("Invalid borrow amount");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    // borrow fail because loan exists
    function testBorrowFailExists() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
        assertEq(sourcePool.getLoan(loanId).borrowTime, block.timestamp);

        // borrow again in same block (same loanId)
        vm.expectRevert("Loan already exists");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    // borrow fail because not enough collateral
    function testBorrowFailNotEnoughCollateral() public {
        // prepare
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 0.1e18; // should be >= 10e18
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        vm.expectRevert("Not enough collateral");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);    
    }

    // borrow fail because gauge killed
    function testBorrowFailGaugeKilled() public {
        // kill gauge
        sourceToken.removeGauge(address(sourcePool));

        // prepare
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        vm.expectRevert("Debt ceiling reached");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);    
    }

    // borrow fail because debt ceiling is reached
    function testBorrowFailDebtCeilingReached() public {
        vm.selectFork(sourceFork);
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 1e18;
        uint256 collateralAmount = 100e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        vm.expectRevert("Debt ceiling reached");
        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    /**
     * @notice Add Collateral
    */

    function testAddCollateralSuccess() public {
        vm.selectFork(sourceFork);
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
        assertEq(sourcePool.getLoan(loanId).collateralAmount, collateralAmount);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);
        sourcePool.addCollateral(loanId, collateralAmount);

        // checks
        assertEq(sourcePool.getLoan(loanId).collateralAmount, collateralAmount * 2);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount * 2);
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
    }

    // addCollateral reverts
    function testAddCollateralFailures() public {
        vm.selectFork(sourceFork);
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
        assertEq(sourcePool.getLoan(loanId).collateralAmount, collateralAmount);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        vm.expectRevert("Invalid collateral amount");
        sourcePool.addCollateral(loanId, 0);
    }

    /**
     * @notice Repay
    */

    function testRepayDifferentNetwork() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 5 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, 0);

        address _receiver = address(sourcePool.poolReceiver());

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        uint256 loanDebt = sourcePool.getLoanDebt(loanId);
        uint256 issuanceBefore = sourcePool.issuance();

        vm.selectFork(destinationFork);
        destinationCCIPBnMToken.drip(address(destinationAccount));
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(destinationAccount), 50 ether);

        destinationAccount.repay(
            _receiver,
            loanId,
            loanDebt,
            sourceChainSelector
        );

        // Repay completed
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);
        assertEq(sourcePool.getLoanDebt(loanId), 0);

        assertEq(sourcePool.getLoan(loanId).closeTime, block.timestamp);
        assertEq(sourcePool.issuance(), issuanceBefore - borrowAmount);
        assertEq(sourceCollateral.balanceOf(address(this)), collateralAmount);
    }

    function testRepaySameNetwork() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 5 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, 0);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        uint256 loanDebt = sourcePool.getLoanDebt(loanId);

        uint256 issuanceBefore = sourcePool.issuance();

        sourceCCIPBnMToken.drip(address(this));
        IERC20(address(sourceCCIPBnMToken)).approve(address(sourcePool), loanDebt);

        sourcePool.repay(loanId, loanDebt, false);

        // Repay completed
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);
        assertEq(sourcePool.getLoanDebt(loanId), 0);

        assertEq(sourcePool.getLoan(loanId).closeTime, block.timestamp);
        assertEq(sourcePool.issuance(), issuanceBefore - borrowAmount);
        assertEq(sourceCollateral.balanceOf(address(this)), collateralAmount);
    }

    /**
     * @notice Call
    */

    function testCallSuccess() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        sourceToken.removeGauge(address(sourcePool));

        // call
        sourcePool.call(loanId);

        assertEq(sourcePool.getLoan(loanId).caller, address(this));
        assertEq(sourcePool.getLoan(loanId).callTime, block.timestamp);
    }

    // call success
    function testCallFailConditionsNotMet() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        vm.roll(block.number + 2);

        // call
        vm.expectRevert("Cannot call");
        sourcePool.call(loanId);
    }

    // call fail because loan doesnt exist
    function testCallFailLoanNotFound() public {
        vm.expectRevert("Loan not found");
        sourcePool.call(bytes32(type(uint256).max));
    }

    // call fail because loan created in same block
    function testCallFailCreatedSameBlock() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        // offboard pool
        sourceToken.removeGauge(address(sourcePool));

        // call
        vm.expectRevert("Loan opened in same block");
        sourcePool.call(loanId);
    }

    // call fail because loan is already called
    function testCallFailAlreadyCalled() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        // offboard pool
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        sourceToken.removeGauge(address(sourcePool));

        // call
        sourcePool.call(loanId);

        // call again
        vm.expectRevert("Loan called");
        sourcePool.call(loanId);
    }

    // full flow test (borrow, call, onBid with good debt)
    function testFlowBorrowCallOnBidGoodDebt() public {
        bytes32 loanId = keccak256(
            abi.encode(address(this), address(sourcePool), block.timestamp)
        );

        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(this)), collateralAmount);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), 0);

        uint256 ccipPoolBalanceBefore = sourceCCIPBnMToken.balanceOf(address(sourcePool));
        uint256 ccipLocalBalanceBefore = sourceCCIPBnMToken.balanceOf(address(this));

        // borrow
        bytes32 loanIdReturned = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
        assertEq(loanId, loanIdReturned);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        uint256 ccipLocalBalanceAfter = destinationCCIPBnMToken.balanceOf(address(this));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);
        uint256 ccipPoolBalanceAfter = sourceCCIPBnMToken.balanceOf(address(sourcePool));

        assertEq(ccipLocalBalanceAfter, ccipLocalBalanceBefore + borrowAmount);
        assertEq(ccipPoolBalanceAfter, ccipPoolBalanceBefore - borrowAmount);
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + sourcePool.YEAR());
        vm.roll(block.number + 1);
        uint256 _ccipAmount = sourceCCIPBnMToken.balanceOf(address(this));

        sourceCCIPBnMToken.drip(address(this)); // + 1e18

        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), _ccipAmount + 1e18);
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount);

        // call
        sourceToken.removeGauge(address(sourcePool));
        address caller = address(1000);
        vm.prank(caller);
        sourcePool.call(loanId);
        vm.stopPrank();
        
        // debt stops accruing after call
        assertEq(sourcePool.getLoanDebt(loanId), 0.011e18);
        vm.warp(block.timestamp + 1300);
        vm.roll(block.number + 100);
        assertEq(sourcePool.getLoanDebt(loanId), 0.011e18);

        assertEq(sourcePool.getLoan(loanId).caller, caller);
        assertEq(sourcePool.getLoan(loanId).callTime, block.timestamp - 1300);
        assertEq(sourcePool.getLoan(loanId).closeTime, 0);
        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), _ccipAmount + 1e18);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), collateralAmount);

        // auction bid
        address bidder = address(1269127618);
        sourceCCIPBnMToken.drip(address(bidder));

        (, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId); 
        assert(ccipTokenFromBidder <= sourceCCIPBnMToken.balanceOf(address(bidder)));

        vm.prank(address(sourceAuctionManager));
        sourcePool.onBid(
            loanId,
            bidder,
            0.2e18, 
            0.8e18, 
            0.011e18
        );

        // check token movements
        assertEq(sourceCollateral.balanceOf(address(this)), 0.2e18); 
        assertEq(sourceCollateral.balanceOf(bidder), 0.8e18); 
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), 0);
    }

    // full flow test (borrow, call, onBid with bad debt)
    function testFlowBorrowCallOnBidBadDebt() public {
        bytes32 loanId = keccak256(
            abi.encode(address(this), address(sourcePool), block.timestamp)
        );

        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(address(this)), collateralAmount);
        assertEq(sourceCollateral.balanceOf(address(sourcePool)), 0);

        // borrow
        bytes32 loanIdReturned = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
        assertEq(loanId, loanIdReturned);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + sourcePool.YEAR());
        vm.roll(block.number + 1);

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourcePool)), 1e18 - 0.01e18);

        // call
        sourceToken.removeGauge(address(sourcePool));
        address caller = address(1000);
        vm.prank(caller);
        sourcePool.call(loanId);

        // auction bid
        address bidder = address(9182098102982);
        sourceCCIPBnMToken.drip(bidder);
  
        vm.prank(address(sourceAuctionManager));
        sourcePool.onBid(
            loanId,
            bidder,
            0, // collateralToBorrower
            1e18, // collateralToBidder
            0.005e18 // creditFromBidder
        );

        // check token movements
        assertEq(sourceCollateral.balanceOf(address(this)), 0);
        assertEq(sourceCollateral.balanceOf(bidder), 1e18);

        // check loss reported
        assertEq(sourceToken.lastGaugeLoss(address(sourcePool)), block.timestamp);
    }

    // can borrow more when CCIP lose value
    function testCanBorrowMoreAfterCCIPLoseValue() public {
        // prank the term to report a loss in another loan
        // this should discount CCIP value by 50%, marking up
        // all loans by 2x.
        assertEq(sourceProfitManager.ccipTokenValue(), 1e18);
        assertEq(sourcePool.maxDebtForCollateral(15e18), 15 * 0.01e18);
        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), int256(-50e18), 0);
        assertEq(sourceProfitManager.ccipTokenValue(), 0.5e18);
        assertEq(sourcePool.maxDebtForCollateral(15e18), 15 * 0.01e18 * 2);

        // borrow
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        // We can borrow the double
        uint256 borrowAmount = 0.02e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + sourcePool.YEAR());
        vm.roll(block.number + 1);
        assertEq(sourcePool.getLoanDebt(loanId), 0.022e18);

        // repay loan
        sourceCCIPBnMToken.drip(address(this));
        sourceCCIPBnMToken.approve(address(sourcePool), 0.022e18);
        sourcePool.repay(loanId, 0.022e18, false);

        // loan is closed
        assertEq(sourcePool.getLoanDebt(loanId), 0);
        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), 1e18 - 0.022e18);
    }

    // active loans are marked up when CCIP lose value
    function testActiveLoansAreMarkedUpWhenCCIPLoseValue() public {
        // prepare
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + sourcePool.YEAR());
        vm.roll(block.number + 1);
        assertEq(sourcePool.getLoanDebt(loanId), 0.011e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(sourceProfitManager.ccipTokenValue(), 1e18);
        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), int256(-50e18), 0);
        assertEq(sourceProfitManager.ccipTokenValue(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(sourcePool.getLoanDebt(loanId), 0.022e18);

        // repay loan
        sourceCCIPBnMToken.drip(address(this));
        sourceCCIPBnMToken.approve(address(sourcePool), 0.022e18);
        sourcePool.repay(loanId, 0.022e18, false);

        // loan is closed
        assertEq(sourcePool.getLoanDebt(loanId), 0);
    }
}
