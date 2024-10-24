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

    uint256 MAX_DEBT_PER_COLLATERAL_TOKEN = 0.01e18;
    uint256 INTEREST_RATE = 0.1e18;
    uint256 MIN_PARTIAL_REPAY_PERCENT = 0.02e18;

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
            MIN_PARTIAL_REPAY_PERCENT   
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

        sourceProfitManager = new ProfitManager(
            address(sourceToken),
            address(sourceRouter),
            address(sourceLinkToken),
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

    /**
     * @notice Constructor
    */

    function testInitializeProfitManager() public {
        vm.selectFork(sourceFork);

        assertEq(sourceProfitManager.gToken(), address(sourceToken));
        assertEq(address(sourceProfitManager.router()), address(sourceRouter));
        assertEq(address(sourceProfitManager.linkToken()), address(sourceLinkToken));
        assertEq(address(sourceProfitManager.ccipToken()), address(sourceCCIPBnMToken));
    }

    /**
     * @notice GetPendingRewards
    */

    function testGetPendingRewards() public {
        vm.selectFork(sourceFork);

        Client.EVMTokenAmount[] memory tokensToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenToSendDetails =
            Client.EVMTokenAmount({token: address(sourceCCIPBnMToken), amount: 1e18});
        tokensToSendDetails[0] = tokenToSendDetails;

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(this), 10 ether);
        sourceCCIPBnMToken.drip(address(this));
        sourceCCIPBnMToken.approve(address(sourceRouter), 1e18);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationToken),
            data: abi.encode(address(destinationPool), address(this)),
            tokenAmounts: tokensToSendDetails,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 2_000_000})
            ),
            feeToken: address(sourceLinkToken)
        });

        uint256 fees = sourceRouter.getFee(destinationChainSelector, message);
        sourceLinkToken.approve(address(sourceRouter), fees);
        sourceRouter.ccipSend(destinationChainSelector, message);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        assertEq(destinationToken.getGaugeWeight(address(destinationPool)), 1e18);

        vm.selectFork(destinationFork);

        destinationCCIPBnMToken.drip(address(destinationProfitManager));

        // Half to the surplus buffer, half to the holders
        destinationProfitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0.5e18  // gTokenSplit
        );

        vm.startPrank(address(destinationPool));
        destinationProfitManager.notifyPnL(
            address(destinationPool),
            2e18, 
            0
        );
        vm.stopPrank();

        // check pending rewards
        address[] memory gauges;
        uint256[] memory gaugeRewards;
        uint256 totalRewards;
        (gauges, gaugeRewards, totalRewards) = destinationProfitManager.getPendingRewards(address(this));
     
        assertEq(gauges.length, 1);
        assertEq(gauges[0], address(destinationPool));
        assertEq(gaugeRewards.length, 1);

        // Half of the profit to the holder
        assertEq(gaugeRewards[0], 1e18);
        assertEq(totalRewards, 1e18);
        assertEq(destinationProfitManager.claimRewards(address(this), address(destinationPool), 0), 1e18);  

        // Another half goes to the surpluss buffer
        assertEq(destinationProfitManager.surplusBuffer(), 1e18);
    }

    function testClaimRewardsSameNetworkAndDiferent() public {
        vm.selectFork(destinationFork);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(this), 50 ether);
        destinationCCIPBnMToken.drip(address(this));
        destinationCCIPBnMToken.approve(address(destinationRouter), 1e18);

        Client.EVMTokenAmount[] memory tokensToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenToSendDetails =
            Client.EVMTokenAmount({token: address(destinationCCIPBnMToken), amount: 1e18});
        tokensToSendDetails[0] = tokenToSendDetails;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(sourceToken),
            data: abi.encode(address(sourcePool), address(this)),
            tokenAmounts: tokensToSendDetails,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 2_000_000})
            ),
            feeToken: address(destinationLinkToken)
        });

        uint256 fees = destinationRouter.getFee(sourceChainSelector, message);
        destinationLinkToken.approve(address(destinationRouter), fees);
        destinationRouter.ccipSend(sourceChainSelector, message);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(sourceFork);

        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 1e18);

        // Claim rewards at the same network
        vm.selectFork(sourceFork);

        // Two times notifyPnl called
        sourceCCIPBnMToken.drip(address(sourceProfitManager));
        sourceCCIPBnMToken.drip(address(sourceProfitManager));

        // Half to the surplus buffer, half to the holders
        sourceProfitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0.5e18  // gTokenSplit
        );

        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(
            address(sourcePool),
            2e18, 
            0
        );
        vm.stopPrank();
        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), 0);

        // Claim rewards
        sourceProfitManager.claimRewards(address(this), address(sourcePool), 0);
        assertEq(sourceCCIPBnMToken.balanceOf(address(this)), 1e18);

        // Claim rewards in diferent network
        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(
            address(sourcePool),
            2e18, 
            0
        );
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourceProfitManager), 10 ether);
        sourceProfitManager.claimRewards(address(this), address(sourcePool), destinationChainSelector);

        // Claim rewards
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        assertEq(destinationCCIPBnMToken.balanceOf(address(this)), 1e18);
    }

    /**
     * @notice CCIP Token Multiplier
    */

    function testCCIPTokenMultiplier() public {
        vm.selectFork(sourceFork);

        assertEq(sourceProfitManager.ccipTokenValue(), 1e18);

        // apply a loss (1)
        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -30e18, 0);
        vm.stopPrank();
        assertEq(sourceProfitManager.ccipTokenValue(), 0.7e18); // 30% discounted

        // apply a loss (2)
        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -20e18, 0);
        vm.stopPrank();
        assertEq(sourceProfitManager.ccipTokenValue(), 0.56e18); // 56% discounted

        // apply a gain on an existing loan
        sourceCCIPBnMToken.drip(address(sourceProfitManager));
        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), 1e18, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        assertEq(sourceProfitManager.ccipTokenValue(), 0.56e18); // unchanged, does not go back up
    }

    /**
     * @notice Issuance
    */

    function testTotalIssuance() public {
        vm.selectFork(sourceFork);
        assertEq(sourceProfitManager.totalIssuance(), 0);
        sourceCCIPBnMToken.drip(address(sourcePool));
        sourceCCIPBnMToken.approve(address(sourceRouter), 0.1e18);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sourcePool), 10 ether);
        
        uint256 borrowAmount = 0.01e18;
        uint256 collateralAmount = 1e18;
        sourceCollateral.mint(address(this), collateralAmount);
        sourceCollateral.approve(address(sourcePool), collateralAmount);

        sourcePool.borrow(collateralAmount, borrowAmount, destinationChainSelector);

        assertEq(sourceProfitManager.totalIssuance(), borrowAmount);
    }

    /**
     * @notice Min Borrow
    */

    function testMinBorrow() public {
        vm.selectFork(sourceFork);
        assertEq(sourceProfitManager.minBorrow(), 0.01e18);

        // apply a loss
        vm.startPrank(address(sourcePool));
        sourceProfitManager.notifyPnL(address(sourcePool), -50e18, 0);
        vm.stopPrank();
        assertEq(sourceProfitManager.ccipTokenValue(), 0.5e18); // 50% discounted

        // minBorrow() should 2x
        assertEq(sourceProfitManager.minBorrow(), 0.02e18);
    }

    /**
     * @notice Profit Sharing Config
    */

    function testSetProfitSharingConfig() public {
        vm.selectFork(sourceFork);

        (
            uint256 surplusBufferSplit,
            uint256 gTokenSplit
        ) = sourceProfitManager.getProfitSharingConfig();
        assertEq(surplusBufferSplit, 0);
        assertEq(gTokenSplit, 0);

        // sum != 100%
        vm.expectRevert("Invalid config");
        sourceProfitManager.setProfitSharingConfig(
            0.1e18, // surplusBufferSplit
            0.1e18  // gTokenSplit
        );

        vm.startPrank(address(3));
        vm.expectRevert("Only callable by owner");
        sourceProfitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0.5e18  // gTokenSplit
        );
        vm.stopPrank();

        // ok
        sourceProfitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0.5e18  // gTokenSplit
        );

        (
            surplusBufferSplit,
            gTokenSplit
        ) = sourceProfitManager.getProfitSharingConfig();
        assertEq(surplusBufferSplit, 0.5e18);
        assertEq(gTokenSplit, 0.5e18);
    }

    /**
     * @notice SetMinBorrow
    */

    function testSetMinBorrow() public {
        vm.selectFork(sourceFork);
        assertEq(sourceProfitManager.minBorrow(), 0.01e18);

        // revert if not owner
        vm.startPrank(address(3));
        vm.expectRevert("Only callable by owner");
        sourceProfitManager.setMinBorrow(1000e18);
        vm.stopPrank();

        assertEq(sourceProfitManager.minBorrow(), 0.01e18);

        // ok
        sourceProfitManager.setMinBorrow(1000e18);

        assertEq(sourceProfitManager.minBorrow(), 1000e18);
    }

    /**
     * @notice SetMaxTotalIssuance
    */

    function testSetMaxTotalIssuance() public {
        vm.selectFork(sourceFork);
        assertEq(sourceProfitManager.maxTotalIssuance(), 1e30);

        // revert if not owner
        vm.startPrank(address(3));
        vm.expectRevert("Only callable by owner");
        sourceProfitManager.setMaxTotalIssuance(1000e18);
        vm.stopPrank();

        assertEq(sourceProfitManager.maxTotalIssuance(), 1e30);

        // ok
        sourceProfitManager.setMaxTotalIssuance(1000e18);

        assertEq(sourceProfitManager.maxTotalIssuance(), 1000e18);
    }
}