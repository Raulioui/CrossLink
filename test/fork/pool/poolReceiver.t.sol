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
    MockERC20 public sourceCollateral;
    ProfitManager public sourceProfitManager;
    GovernanceToken public sourceToken;
    AuctionManager public sourceAuctionManager;
    PoolReceiver public sourcePoolReceiver;

    PersonalAccount public destinationAccount;
    
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

        sourcePoolReceiver = new PoolReceiver(
            address(sourceRouter),
            address(sourcePool),
            address(sourceCCIPBnMToken),
            address(sourceProfitManager)
        );

        sourceToken.setMaxGauges(10);
    }

    /**
     * @notice Initiate
    */

    function testConstructorPoolReceiver() public {
        assertEq(sourcePoolReceiver.pool(), address(sourcePool));
        assertEq(sourcePoolReceiver.ccipToken(), sourcePool.ccipToken());
        assertEq(sourcePoolReceiver.profitManager(), address(sourceProfitManager));
    }

    /**
     * @notice Send CCIP
    */

    function testReceiveAndSendCCIP() public {
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