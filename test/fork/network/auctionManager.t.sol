// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "lib/chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BurnMintERC677Helper, IERC20} from "lib/chainlink-local/src/ccip/CCIPLocalSimulator.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Pool} from "../../../src/pool/Pool.sol";
import {MockERC20} from "../../../mock/ERC20Mock.sol";
import {ProfitManager} from "../../../src/network/ProfitManager.sol";
import {GovernanceToken} from "../../../src/tokens/GovernanceToken.sol";
import {AuctionManager} from "../../../src/network/AuctionManager.sol";
import {PersonalAccount} from "../../../src/user/PersonalAccount.sol";

contract TestAuctionManager is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    uint256 public sourceFork;
    uint256 public destinationFork;

    IRouterClient public sourceRouter;
    IRouterClient public destinationRouter;

    uint64 public destinationChainSelector;
    uint64 public sourceChainSelector;

    PersonalAccount public sourceAccount;
    PersonalAccount public destinationAccount;

    BurnMintERC677Helper public sourceCCIPBnMToken;
    BurnMintERC677Helper public destinationCCIPBnMToken;

    IERC20 public sourceLinkToken;
    IERC20 public destinationLinkToken;

    Pool public sourcePool;

    MockERC20 public sourceCollateral;

    ProfitManager public sourceProfitManager;

    GovernanceToken public sourceToken;

    AuctionManager public sourceAuctionManager;

    uint256 MAX_DEBT_PER_COLLATERAL_TOKEN = 0.01e18;
    uint256 INTEREST_RATE = 0;
    uint256 MIN_PARTIAL_REPAY_PERCENT = 0;

    uint256 public constant MID_POINT = 650;
    uint256 public constant AUCTION_DURATION = 1800;
    uint256 public constant STARTING_COLLATERAL = 0;

    function setUp() public {
        string memory DESTINATION_RPC_URL = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        string memory SOURCE_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        
        destinationFork = vm.createSelectFork(DESTINATION_RPC_URL);
        sourceFork = vm.createFork(SOURCE_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));
        
        Register.NetworkDetails
            memory destinationNetworkDetails = ccipLocalSimulatorFork
                .getNetworkDetails(block.chainid);
        destinationCCIPBnMToken = BurnMintERC677Helper(destinationNetworkDetails.ccipBnMAddress);
        destinationLinkToken = IERC20(destinationNetworkDetails.linkAddress);
        destinationRouter = IRouterClient(destinationNetworkDetails.routerAddress);

        destinationChainSelector = destinationNetworkDetails.chainSelector;

        destinationAccount = new PersonalAccount(
            address(destinationLinkToken),
            address(destinationRouter),
            address(destinationCCIPBnMToken)
        );

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

        sourceToken.setMaxGauges(10);
    }

    function createLoan() internal returns (bytes32 loanId) {
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 10 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);
        // borrow
        return loanId = sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);
    }

    /**
     * @notice Constructor
    */

    function testinitializeAuctionManager() public {
        assertEq(sourceAuctionManager.midPoint(), MID_POINT);
        assertEq(sourceAuctionManager.auctionDuration(), AUCTION_DURATION);
        assertEq(sourceAuctionManager.startCollateralOffered(), STARTING_COLLATERAL);
        assertEq(sourceAuctionManager.profitManager(), address(sourceProfitManager));
    }

    /**
     * @notice Start Auction
    */

    function testStartAuction() public {
        bytes32 loanId = createLoan();

        vm.warp(block.timestamp + 1300);
        vm.roll(block.number + 100);

        sourceToken.removeGauge(address(sourcePool));

        vm.prank(address(sourcePool));
        sourcePool.call(loanId);

        uint256 callDebt = sourcePool.getLoan(loanId).callDebt;
        uint256 ccipTokenValue = sourceProfitManager.ccipTokenValue();

        assertEq(sourceAuctionManager.auctionsInProgress(), 1);

        assertEq(sourceAuctionManager.getAuction(loanId).startTime, uint48(block.timestamp));
        assertEq(sourceAuctionManager.getAuction(loanId).endTime, 0);
        assertEq(sourceAuctionManager.getAuction(loanId).pool, address(sourcePool));
        assertEq(sourceAuctionManager.getAuction(loanId).collateralAmount, 1e18);
        assertEq(sourceAuctionManager.getAuction(loanId).callDebt, callDebt);
        assertEq(sourceAuctionManager.getAuction(loanId).callCCIPTokenValue, ccipTokenValue);
    }

    function testRevertsIfCallerIsNotThePool() public {
        bytes32 loanId = createLoan();

        vm.expectRevert();
        sourceAuctionManager.startAuction(loanId);
    }

    /**
     * @notice Bid
    */

    function testBidDifferentNetwork() public {
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

    function testBidSameNetwork() public {
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

        (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);

        IERC20(sourceCCIPBnMToken).approve(address(sourceAuctionManager), ccipTokenFromBidder);

        sourceAuctionManager.bid(
            loanId,
            collateralToBidder,
            ccipTokenFromBidder,
            false
        );

        // The ccip arrives to the auction manager
        assertEq(sourceCCIPBnMToken.balanceOf(address(sourceAuctionManager)), ccipTokenFromBidder);
        
        // Auction ends
        assertEq(sourceAuctionManager.getAuction(loanId).endTime, uint48(block.timestamp));
        assertEq(sourceAuctionManager.auctionsInProgress(), 0);
    }

    /**
     * @notice GetBidDetail
    */

    // getBidDetail at various steps
    function testGetBidDetail() public {
        bytes32 loanId = createLoan();
        vm.warp(block.timestamp + sourcePool.YEAR());
        vm.roll(block.number + 1);

        sourceToken.removeGauge(address(sourcePool));

        assertEq(sourceCollateral.balanceOf(address(this)), 0);  

        // Start auction
        vm.prank(address(sourcePool));
        sourcePool.call(loanId);

        assertEq(sourceAuctionManager.getAuction(loanId).collateralAmount, 1e18);
        assertEq(sourceAuctionManager.getAuction(loanId).callDebt, 0.01e18);

        uint256 PHASE_1_DURATION = sourceAuctionManager.midPoint();
        uint256 PHASE_2_DURATION = sourceAuctionManager.auctionDuration() -
            sourceAuctionManager.midPoint();

        // right at the start of auction
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 0); // 0% of initial collateral
            assertEq(ccipTokenFromBidder, 0.01e18); // full debt
        }

        // 10% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 0.1e18); // 10% of initial collateral
            assertEq(ccipTokenFromBidder, 0.01e18); // full debt
        }
        
        // 50% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (PHASE_1_DURATION * 4) / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 0.5e18); // 50% of initial collateral
            assertEq(ccipTokenFromBidder, 0.01e18); // full debt
        }

        // 90% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (PHASE_1_DURATION * 4) / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 0.9e18); // 90% of initial collateral
            assertEq(ccipTokenFromBidder, 0.01e18); // full debt
        }

        // at midpoint
        // offer all collateral, ask all debt
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18);
            assertEq(ccipTokenFromBidder, 0.01e18);
        }

        // 10% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18); // full collateral
            assertEq(ccipTokenFromBidder, 0.009e18); // 90% of debt
        }

        // 50% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (PHASE_2_DURATION * 4) / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18); // full collateral
            assertEq(ccipTokenFromBidder, 0.005e18); // 50% of debt
        }

        // 90% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + (PHASE_2_DURATION * 4) / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18); // full collateral
            assertEq(ccipTokenFromBidder, 0.001e18); // 10% of debt
        }

        // end of second phase (= end of auction)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION / 10);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18);
            assertEq(ccipTokenFromBidder, 0);
        }

        // after end of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 123456);
        {
            (uint256 collateralToBidder, uint256 ccipTokenFromBidder) = sourceAuctionManager.getBidDetail(loanId);
            assertEq(collateralToBidder, 1e18);
            assertEq(ccipTokenFromBidder, 0);
        }
    }
}