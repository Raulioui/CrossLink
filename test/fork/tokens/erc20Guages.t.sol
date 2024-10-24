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

     function testInitialState() public {
        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 0);
        assertEq(sourceToken.getUserWeight(address(this)), 0);
        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 0);
        assertEq(sourceToken.totalWeight(), 0);
        assertEq(sourceToken.gauges().length, 2);
        assertEq(sourceToken.isGauge(address(sourcePool)), true);
        assertEq(sourceToken.isGauge(address(1)), false);
        assertEq(sourceToken.numGauges(), 2);
        assertEq(sourceToken.deprecatedGauges().length, 0);
        assertEq(sourceToken.numDeprecatedGauges(), 0);
        assertEq(sourceToken.userGauges(address(this)).length, 0);
        assertEq(sourceToken.isUserGauge(address(this), address(sourcePool)), false);
    }


    function testSetMaxGauges(uint256 max) public {
        sourceToken.setMaxGauges(max);
        require(sourceToken.maxGauges() == max);
    }

    function testSetCanExceedMaxGauges() public {
        sourceToken.setCanExceedMaxGauges(address(this), true);
        require(sourceToken.canExceedMaxGauges(address(this)));

        // revert for non-smart contracts
        vm.expectRevert("Not a smart contract");
        sourceToken.setCanExceedMaxGauges(address(0xBEEF), true);
    }

    function testAddGauge() public {
        Pool newPool = new Pool(
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

        assertEq(sourceToken.isGauge(address(newPool)), true);
    }

    function testLiveAndDeprecatedGaugeGetters() public {
        assert(sourceToken.numLiveGauges() == 2);
        assert(sourceToken.liveGauges().length == 2);
        assert(sourceToken.numDeprecatedGauges() == 0);
        assert(sourceToken.deprecatedGauges().length == 0);
        assert(sourceToken.numGauges() == 2);

        assert(sourceToken.gauges()[0] == address(sourcePool));
        assert(sourceToken.gauges()[1] == address(sourcePool2));
        assert(sourceToken.liveGauges()[0] == address(sourcePool));
        assert(sourceToken.liveGauges()[1] == address(sourcePool2));

        sourceToken.removeGauge(address(sourcePool));

        assert(sourceToken.numGauges() == 2);
        assert(sourceToken.gauges()[0] == address(sourcePool));
        assert(sourceToken.gauges()[1] == address(sourcePool2));
        assert(sourceToken.numLiveGauges() == 1);
        assert(sourceToken.liveGauges().length == 1);
        assert(sourceToken.liveGauges()[0] == address(sourcePool2));
        assert(sourceToken.numDeprecatedGauges() == 1);
        assert(sourceToken.deprecatedGauges().length == 1);
        assert(sourceToken.deprecatedGauges()[0] == address(sourcePool));

        sourceToken.addGauge(address(sourcePool)); // re-add previously deprecated

        assert(sourceToken.numGauges() == 2);
        assert(sourceToken.gauges()[0] == address(sourcePool));
        assert(sourceToken.gauges()[1] == address(sourcePool2));
        assert(sourceToken.numLiveGauges() == 2);
        assert(sourceToken.liveGauges().length == 2);
        assert(sourceToken.liveGauges()[0] == address(sourcePool));
        assert(sourceToken.liveGauges()[1] == address(sourcePool2));
        assert(sourceToken.numDeprecatedGauges() == 0);
        assert(sourceToken.deprecatedGauges().length == 0);

        sourceToken.removeGauge(address(sourcePool2));

        assert(sourceToken.numGauges() == 2);
        assert(sourceToken.gauges()[0] == address(sourcePool));
        assert(sourceToken.gauges()[1] == address(sourcePool2));
        assert(sourceToken.numLiveGauges() == 1);
        assert(sourceToken.liveGauges().length == 1);
        assert(sourceToken.liveGauges()[0] == address(sourcePool));
        assert(sourceToken.numDeprecatedGauges() == 1);
        assert(sourceToken.deprecatedGauges().length == 1);
        assert(sourceToken.deprecatedGauges()[0] == address(sourcePool2));

        sourceToken.removeGauge(address(sourcePool));

        assert(sourceToken.numGauges() == 2);
        assert(sourceToken.gauges()[0] == address(sourcePool));
        assert(sourceToken.gauges()[1] == address(sourcePool2));
        assert(sourceToken.numLiveGauges() == 0);
        assert(sourceToken.liveGauges().length == 0);
        assert(sourceToken.numDeprecatedGauges() == 2);
        assert(sourceToken.deprecatedGauges().length == 2);
        assert(sourceToken.deprecatedGauges()[0] == address(sourcePool2));
        assert(sourceToken.deprecatedGauges()[1] == address(sourcePool));
    }

    function testRemoveGauge() public {
        assertEq(sourceToken.isDeprecatedGauge(address(sourcePool)), false);
        sourceToken.removeGauge(address(sourcePool));
        assertEq(sourceToken.numDeprecatedGauges(), 1);
        assertEq(sourceToken.deprecatedGauges()[0], address(sourcePool));
        assertEq(sourceToken.isDeprecatedGauge(address(sourcePool)), true);
    }

    function testRemoveUnexistingGauge() public {
        vm.expectRevert("Invalid gauge");
        sourceToken.removeGauge(address(12345));
    }

    function testRemoveGaugeWithWeight() public {
        // Add weight
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        sourceToken.removeGauge(address(sourcePool));
        require(sourceToken.numGauges() == 2);
        require(sourceToken.numDeprecatedGauges() == 1);
        require(sourceToken.totalWeight() == 0);
        require(sourceToken.getGaugeWeight(address(sourcePool)) == stakedAmount);
        require(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)) == stakedAmount);
    }

    /// @notice test incrementing over user max
    function testIncrementOverMax() public {
        sourceToken.setMaxGauges(1);
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        vm.expectRevert("Max gauges exceeded");
        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool2),
            false
        );
    }

    /// @notice test incrementing at user max
    function testIncrementAtMax() public {
        sourceToken.setMaxGauges(1);

        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 2e18);
        assertEq(sourceToken.getUserWeight(address(this)), 2e18);
        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 2e18);
        assertEq(sourceToken.totalWeight(), 2e18);
    }

    function testIncrementOnDeprecated() public {
        sourceToken.removeGauge(address(sourcePool));

        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        vm.expectRevert("Invalid gauge");
        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );
    }

    function testDecrement() public {
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        sourceCCIPBnMToken.drip(address(sourceProfitManager)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 1e18);

        vm.startPrank(address(sourceToken));
        sourceToken.decrementGauge(address(sourcePool), 1e18, address(this));
        
        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 0);
    }

    function testDecrementDeprecatedGauge() public {        
        uint256 stakedAmount = 1e18;
        sourceCCIPBnMToken.drip(address(this)); 
        sourceCCIPBnMToken.drip(address(sourceProfitManager)); 
        IERC20(sourceCCIPBnMToken).approve(address(sourceToken), stakedAmount);

        sourceToken.stake(
            stakedAmount,
            address(this),
            address(sourcePool),
            false
        );

        assertEq(sourceToken.totalWeight(), 1e18);
        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 1e18);
        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 1e18);
        assertEq(sourceToken.getUserWeight(address(this)), 1e18);

        sourceToken.removeGauge(address(sourcePool));

        assertEq(sourceToken.totalWeight(), 0);
        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 1e18);
        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 1e18);
        assertEq(sourceToken.getUserWeight(address(this)), 1e18);

        vm.startPrank(address(sourceToken));
        sourceToken.decrementGauge(address(sourcePool), 1e18, address(this));

        assertEq(sourceToken.totalWeight(), 0);
        assertEq(sourceToken.getGaugeWeight(address(sourcePool)), 0);
        assertEq(sourceToken.getUserGaugeWeight(address(this), address(sourcePool)), 0);
        assertEq(sourceToken.getUserWeight(address(this)), 0);
    }
}