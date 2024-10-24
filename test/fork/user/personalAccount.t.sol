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

contract PersonalAccountTest is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    uint256 public sourceFork;
    uint256 public destinationFork;
    uint256 public aditionalFork;

    address public bob;

    IRouterClient public sourceRouter;
    IRouterClient public destinationRouter;

    uint64 public destinationChainSelector;
    uint64 public sourceChainSelector;
    uint64 public aditionalChainSelector;

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
    uint256 MIN_PARTIAL_REPAY_PERCENT = 0.02e18;

    bytes32 _loanId;

    function setUp() public {
        string memory DESTINATION_RPC_URL = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        string memory SOURCE_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        string memory ADITIONAL_RPC_URL = vm.envString("OPTIMISM_SEPOLIA_RPC_URL");

        bob = makeAddr("bob");
        
        destinationFork = vm.createSelectFork(DESTINATION_RPC_URL);
        sourceFork = vm.createFork(SOURCE_RPC_URL);
        aditionalFork = vm.createFork(ADITIONAL_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        
        Register.NetworkDetails
            memory destinationNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);
        destinationCCIPBnMToken = BurnMintERC677Helper(destinationNetworkDetails.ccipBnMAddress);
        destinationLinkToken = IERC20(destinationNetworkDetails.linkAddress);
        destinationRouter = IRouterClient(destinationNetworkDetails.routerAddress);

        destinationChainSelector = destinationNetworkDetails.chainSelector;

        destinationProfitManager = new ProfitManager(
            address(destinationToken),
            address(destinationRouter),
            address(destinationLinkToken),
            address(destinationCCIPBnMToken)
        );

        destinationToken = new GovernanceToken(
            address(destinationRouter),
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
            MIN_PARTIAL_REPAY_PERCENT   
        );

        destinationAccount = new PersonalAccount(
            address(destinationLinkToken),
            address(destinationRouter),
            address(destinationCCIPBnMToken)
        );

        destinationToken.setMaxGauges(10);

        vm.selectFork(aditionalFork);

        Register.NetworkDetails
            memory aditionalNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);

        aditionalChainSelector = aditionalNetworkDetails.chainSelector;

        vm.selectFork(sourceFork);

        Register.NetworkDetails
            memory sourceNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);
        sourceCCIPBnMToken = BurnMintERC677Helper(sourceNetworkDetails.ccipBnMAddress);
        sourceLinkToken = IERC20(sourceNetworkDetails.linkAddress);
        sourceRouter = IRouterClient(sourceNetworkDetails.routerAddress);
        sourceChainSelector = sourceNetworkDetails.chainSelector;

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

        sourceToken = new GovernanceToken(
            address(sourceRouter),
            address(sourceCCIPBnMToken)
        );


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
            MIN_PARTIAL_REPAY_PERCENT   
        );


        sourceAccount = new PersonalAccount(
            address(sourceLinkToken),
            address(sourceRouter),
            address(sourceCCIPBnMToken)
        );

        sourceToken.setMaxGauges(10);
    }

    /**
     * @notice Stake
    */

    function testStakeFromAccount() public {
        vm.startPrank(address(sourceAccount));

        // Fund the user account
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(sourceAccount)); 
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourceAccount), 5 ether);

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourceAccount)), stakedAmount);

        sourceAccount.stake(
            address(destinationToken),
            stakedAmount,
            destinationChainSelector,
            address(destinationPool),
            bob
        );

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourceAccount)), 0);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        // The pool receives the CCIP
        assertEq(destinationCCIPBnMToken.balanceOf(address(destinationPool)), stakedAmount);
       
        // The user receives the gToken
        uint256 mintRatio = destinationToken.mintRatio();
        assertEq(destinationToken.balanceOf(address(bob)), mintRatio * stakedAmount / 1e18);

        // Increment weights
        assertEq(destinationToken.getUserGaugeWeight(address(bob), address(destinationPool)), stakedAmount);
        assertEq(destinationToken.getGaugeWeight(address(destinationPool)), stakedAmount);

        uint256 userGaugeProfitIndex = destinationProfitManager.userGaugeProfitIndex(address(sourceAccount), address(destinationPool));
        uint256 amountStakedConversion = destinationToken.mintRatio() * stakedAmount / 1e18; 

        // UserStake
        assertEq(destinationToken.getUserStake(bob, address(destinationPool)).stakeTime, block.timestamp);
        assertEq(destinationToken.getUserStake(bob, address(destinationPool)).profitIndex, userGaugeProfitIndex);
        assertEq(destinationToken.getUserStake(bob, address(destinationPool)).ccip, stakedAmount);
        assertEq(destinationToken.getUserStake(bob, address(destinationPool)).gToken, amountStakedConversion);
    }

    /**
     * @notice Bid
    */

    /// @dev The bid transfer douesn't work becaouse already ccip transfer did at pool.borrow
    function testBidFromAccount() public {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);
     
        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, 0);

        vm.warp(block.timestamp + 1300);
        vm.roll(block.number + 100);

        sourceToken.removeGauge(address(sourcePool));

        vm.prank(address(sourcePool));
        sourcePool.call(loanId);
        vm.stopPrank();

        (, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);

        vm.selectFork(destinationFork);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(destinationAccount), 100 ether);
        destinationCCIPBnMToken.drip(address(destinationAccount));

        destinationAccount.bid(
            loanId,
            address(sourceAuctionManager),
            ccipTokenFromBidder,
            sourceChainSelector
        );

        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);

        // The ccip arrives to the auction manager
        assertEq(sourceCCIPBnMToken.balanceOf(address(sourceAuctionManager)), ccipTokenFromBidder);
        
        // Auction ends
        assertEq(sourceAuctionManager.getAuction(loanId).endTime, uint48(block.timestamp));
        assertEq(sourceAuctionManager.auctionsInProgress(), 0);
    }

    /**
     * @notice Repay
    */

    function testRepayFromAccount() public {
        vm.selectFork(sourceFork);
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 100 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);
     
        // borrow
        bytes32 loanId = sourcePool.borrow(collateralAmount, borrowAmount, 0);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        uint256 loanDebt = sourcePool.getLoanDebt(loanId);
        address _poolReceiver = address(sourcePool.poolReceiver());

        // Repay thought the user account
        vm.selectFork(destinationFork);

        destinationCCIPBnMToken.drip(address(destinationAccount));
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(destinationAccount), 50 ether);

        destinationAccount.repay(
            _poolReceiver,
            loanId,
            loanDebt,
            sourceChainSelector
        );

        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);

        // Repay completed
        assertEq(sourcePool.getLoanDebt(loanId), 0);
    }
}