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

    BurnMintERC677Helper public sourceCCIPBnMToken;
    BurnMintERC677Helper public destinationCCIPBnMToken;

    IERC20 public sourceLinkToken;
    IERC20 public destinationLinkToken;

    Pool public sourcePool;
    Pool public sourcePool2;
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
    uint256 INTEREST_RATE = 0;
    uint256 MIN_PARTIAL_REPAY_PERCENT = 0;

    uint256 public constant MID_POINT = 650;
    uint256 public constant AUCTION_DURATION = 1800;
    uint256 public constant STARTING_COLLATERAL = 0;

    address public alice;

    function setUp() public {
        string memory DESTINATION_RPC_URL = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        string memory SOURCE_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");

        alice = makeAddr("alice");
        
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
            MIN_PARTIAL_REPAY_PERCENT   
        );

        sourcePool2  = new Pool(
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

    function _setupAliceLossInGauge1() internal {
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            alice,
            address(sourcePool),
            false
        );

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // loss in gauge1
        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -100, 0);
        vm.stopPrank();
    }

    /**
     * @notice Receive CCIP and stake
    */

    function testReceiveCCIPStakeDifferentNetwork() public {
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
            alice
        );

        assertEq(sourceCCIPBnMToken.balanceOf(address(sourceAccount)), 0);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        // The pool receives the CCIP
        assertEq(destinationCCIPBnMToken.balanceOf(address(destinationPool)), stakedAmount);
       
        // The user receives the gToken
        uint256 mintRatio = destinationToken.mintRatio();
        assertEq(destinationToken.balanceOf(alice), mintRatio * stakedAmount / 1e18);

        // Increment weights
        assertEq(destinationToken.getUserGaugeWeight(alice, address(destinationPool)), stakedAmount);
        assertEq(destinationToken.getGaugeWeight(address(destinationPool)), stakedAmount);

        uint256 userGaugeProfitIndex = destinationProfitManager.userGaugeProfitIndex(address(sourceAccount), address(destinationPool));
        uint256 amountStakedConversion = destinationToken.mintRatio() * stakedAmount / 1e18; 

        // UserStake
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).stakeTime, block.timestamp);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).profitIndex, userGaugeProfitIndex);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).ccip, stakedAmount);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).gToken, amountStakedConversion);
    }

    function testStakeSameNetwork() public {
        vm.selectFork(destinationFork);

        // Fund the user account
        uint256 stakedAmount = 1e18;
        destinationCCIPBnMToken.drip(address(this)); 
        IERC20(destinationCCIPBnMToken).approve(address(destinationToken), stakedAmount);

        destinationToken.stake(
            stakedAmount,
            alice,
            address(destinationPool),
            false
        );

        // The pool receives the CCIP
        assertEq(destinationCCIPBnMToken.balanceOf(address(destinationPool)), stakedAmount);
       
        // The user receives the gToken
        uint256 mintRatio = destinationToken.mintRatio();
        assertEq(destinationToken.balanceOf(alice), mintRatio * stakedAmount / 1e18);

        // Increment weights
        assertEq(destinationToken.getUserGaugeWeight(alice, address(destinationPool)), stakedAmount);
        assertEq(destinationToken.getGaugeWeight(address(destinationPool)), stakedAmount);

        uint256 userGaugeProfitIndex = destinationProfitManager.userGaugeProfitIndex(address(sourceAccount), address(destinationPool));
        uint256 amountStakedConversion = destinationToken.mintRatio() * stakedAmount / 1e18; 

        // UserStake
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).stakeTime, block.timestamp);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).profitIndex, userGaugeProfitIndex);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).ccip, stakedAmount);
        assertEq(destinationToken.getUserStake(alice, address(destinationPool)).gToken, amountStakedConversion);
    }

    /**
     * @notice Gauge managment
    */

    function testRemoveGauge() public {
        // revert because user doesn't have access
        vm.startPrank(address(0));
        vm.expectRevert("Ownable: caller is not the owner");
        sourceToken.removeGauge(address(sourcePool));
        vm.stopPrank();

        sourceToken.removeGauge(address(sourcePool));
        assertEq(sourceToken.isGauge(address(sourcePool)), false);
    }

    function testSetMaxGauges() public {
        // revert because user doesn't have access
        vm.startPrank(address(0));
        vm.expectRevert("Ownable: caller is not the owner");
        sourceToken.setMaxGauges(42);
        vm.stopPrank();

        // successful call & check
        sourceToken.setMaxGauges(42);
        assertEq(sourceToken.maxGauges(), 42);
    }

    function testSetCanExceedMaxGauges() public {
        // revert because user doesn't have access
        vm.startPrank(address(0));
        vm.expectRevert("Ownable: caller is not the owner");
        sourceToken.setCanExceedMaxGauges(address(1), true);
        vm.stopPrank();

        // successful call & check
        sourceToken.setCanExceedMaxGauges(address(this), true);
        assertEq(sourceToken.canExceedMaxGauges(address(this)), true);
    }

    /**
     * @notice Loss management
    */

    function testNotifyPnLLastGaugeLoss() public {
        assertEq(sourceToken.lastGaugeLoss(address(sourcePool)), 0);

        // revert because user doesn't have role
        vm.expectRevert();
        sourceProfitManager.notifyPnL(address(sourcePool), 1, 0);

        // successful call & check
        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -1, 0);
        assertEq(sourceToken.lastGaugeLoss(address(sourcePool)), block.timestamp);

        // successful call & check
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), 1, 0);
        assertEq(sourceToken.lastGaugeLoss(address(sourcePool)), block.timestamp - 13);
    }

    function testApplyGaugeLoss() public {
        // revert if the gauge has no reported loss yet
        vm.expectRevert("No loss to apply");
        sourceToken.applyGaugeLoss(address(sourcePool), alice);
        vm.selectFork(destinationFork);
        vm.startPrank(address(destinationAccount));

        // Fund the user account
        uint256 stakedAmount = 1e18;
        destinationCCIPBnMToken.drip(address(destinationAccount)); 
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(destinationAccount), 50 ether);

        assertEq(destinationCCIPBnMToken.balanceOf(address(destinationAccount)), stakedAmount);

        destinationAccount.stake(
            address(sourceToken),
            stakedAmount,
            sourceChainSelector,
            address(sourcePool),
            alice
        );

        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);

        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), stakedAmount);
        assertEq(sourceToken.getUserWeight(alice), stakedAmount);

        // roll to next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        vm.selectFork(sourceFork);

        sourceCCIPBnMToken.drip(address(sourceProfitManager));

        // loss in gauge1
        vm.prank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -100, 0);
        vm.stopPrank();

        // realize loss in gauge 1
        sourceToken.applyGaugeLoss(address(sourcePool), alice);
        assertEq(sourceToken.lastGaugeLossApplied(address(sourcePool), alice), block.timestamp);
        assertEq(sourceToken.balanceOf(alice), stakedAmount);
        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourceToken)), 0);
    }

    function testCannotIncrementGaugeIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        sourceCCIPBnMToken.drip(address(sourceProfitManager));
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), 1e18);

        // cannot increment gauges that have been affected by the loss
        vm.expectRevert("Pending loss");
        sourceToken.stake(
            1e18,
            alice,
            address(sourcePool),
            false
        );

        // realize loss in gauge 1
        sourceToken.applyGaugeLoss(address(sourcePool), alice);

        assertEq(sourceToken.balanceOf(alice), 1e18);
    }

    function testCanIncrementGaugeIfZeroWeightAndPastLossUnapplied() public {
        _setupAliceLossInGauge1();

        // loss in gauge 3
        vm.startPrank(address(sourceAuctionManager));
        sourceProfitManager.notifyPnL(address(sourcePool2), -100, 0);
        vm.stopPrank();
     
        // roll to next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // can increment gauge for the first time, event if it had a loss in the past
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), 1e18);

        sourceToken.stake(
            1e18,
            alice,
            address(sourcePool2),
            false
        );

        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 1e18);

        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool2)), 1e18);
        assertEq(sourceToken.getUserWeight(alice), 2e18);

        // the past loss does not apply to alice
        vm.expectRevert("No loss to apply");
        sourceToken.applyGaugeLoss(address(sourcePool2), alice);
    }

    function testCannotDecrementGaugeIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        sourceCCIPBnMToken.drip(address(sourceProfitManager));
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), 1e18);

        sourceToken.stake(
            1e18,
            alice,
            address(sourcePool2),
            false
        );

        // cannot decrement gauges that have been affected by the loss
        vm.startPrank(address(sourceToken));
        vm.expectRevert("Pending loss");
        sourceToken.decrementGauge(address(sourcePool), 1e18, alice);
 
        // realize loss in gauge 1
        sourceToken.applyGaugeLoss(address(sourcePool), alice);

        assertEq(sourceToken.balanceOf(alice), 3e18);
    }

    function testDecrementWeightDeprecatedOnlyGauge() public {
        sourceCCIPBnMToken.drip(address(sourceProfitManager));

        // allocate weight to gauge
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            alice,
            address(sourcePool),
            false
        );

        assertEq(sourceToken.totalWeight(), 1e18);
        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 1e18);

        // deprecate gauge
        sourceToken.removeGauge(address(sourcePool));

        assertEq(sourceToken.totalWeight(), 0);
        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 1e18);

        // decrement weight
        vm.startPrank(address(sourceToken));
        sourceToken.decrementGauge(address(sourcePool), 1e18, alice);

        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 0);
    }

    function testGetRewardsWhenDecrementGauge() public {
        sourceCCIPBnMToken.drip(address(sourceProfitManager));

        // allocate weight to gauge
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            alice,
            address(sourcePool),
            false
        );

        assertEq(sourceCCIPBnMToken.balanceOf(alice), 0);

        assertEq(sourceToken.totalWeight(), 1e18);
        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 1e18);

        // deprecate gauge
        sourceToken.removeGauge(address(sourcePool));

        assertEq(sourceToken.totalWeight(), 0);
        assertEq(sourceToken.getUserGaugeWeight(alice, address(sourcePool)), 1e18);

        // decrement weight
        vm.startPrank(address(sourceToken));
        sourceToken.decrementGauge(address(sourcePool), 1e18, alice);
        vm.stopPrank();

        // Alice get the rewards
        assertEq(sourceCCIPBnMToken.balanceOf(alice), 1e18);
    }
}