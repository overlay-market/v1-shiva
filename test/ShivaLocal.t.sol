// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Constants} from "./utils/Constants.sol";
import {MarketImpersonator} from "./utils/MarketImpersonator.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {ShivaTest} from "./Shiva.t.sol";
import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {IBerachainRewardsVaultFactory} from "src/interfaces/berachain/IRewardVaults.sol";
import {IFluxAggregator} from "src/interfaces/aggregator/IFluxAggregator.sol";

import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IOverlayV1ChainlinkFeed} from
    "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {LIQUIDATE_CALLBACK_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";

/**
 * @title ShivaLocalTest
 * @notice Test suite for the Shiva contract
 * @dev This contract uses new deployments instead of the existing contracts
 * @dev Tests from ShivaTest are inherited and run on the new deployments
 */
contract ShivaLocalTest is Test, ShivaTestBase, ShivaTest {
    using FixedPoint for uint256;

    /**
     * @dev Sets up the initial state for the ShivaBase test contract
     * @dev Overrides the setUp method in ShivaBase
     */
    function setUp() public override {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), Constants.getForkBlock());

        // deploy the contracts
        vm.startPrank(deployer);
        ovlToken = deployToken();
        ovlFactory = deployFactory(ovlToken);
        ovlMarket = deployMarket(ovlFactory, Constants.getEthdFeed());
        ovlState = deployPeriphery(ovlFactory);

        // Set Vault Factory
        IBerachainRewardsVaultFactory vaultFactory =
            IBerachainRewardsVaultFactory(Constants.getVaultFactoryAddress());

        // Deploy Shiva contract using ERC1967Proxy pattern and initialize it with necessary parameters
        Shiva shivaImplementation = new Shiva();
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(
            functionName, address(ovlToken), address(ovlState), address(vaultFactory)
        );

        // Set up shiva contract and reward vault
        shiva = Shiva(address(new ERC1967Proxy(address(shivaImplementation), data)));
        rewardVault = shiva.rewardVault();

        // configure liquidation callback role
        ovlToken.grantRole(LIQUIDATE_CALLBACK_ROLE, address(shiva));
        vm.stopPrank();

        // Set up test addresses
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");
        guardian = Constants.getGuardianAddress();
        pauser = Constants.getPauserAddress();

        // Call helper functions
        labelAddresses();
        setInitialBalancesAndApprovals();
        addAuthorizedFactory();
    }

    /**
     * @dev Group of tests for the stake rewards liquidate workflow
     */

    /**
     * @dev Test that the rewards are 0 after a position is liquidated
     */
    function test_liquidate_pol() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // submit a new round with price = prevPrice / 2 to make the posId liquidatable
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
        }
        assertTrue(ovlState.liquidatable(ovlMarket, address(shiva), posId));

        // liquidate alice's position
        vm.startPrank(bob);
        ovlMarket.liquidate(address(shiva), posId);
        (
            , //uint96 notionalInitial_,
            , //uint96 debtInitial_,
            , //int24 midTick_,
            , //int24 entryTick_,
            , //bool isLong_,
            bool liquidated_,
            , //uint240 oiShares_,
                //uint16 fractionRemaining_
        ) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(liquidated_);

        // rewards balance should be 0 after the position is liquidated
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test that liquidate fails when Shiva is paused
     */
    function test_liquidate_pausedShiva() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // submit a new round with price = prevPrice / 2 to make the posId liquidatable
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
        }
        assertTrue(ovlState.liquidatable(ovlMarket, address(shiva), posId));
        vm.stopPrank();

        pauseShiva();

        // liquidate alice's position
        vm.startPrank(bob);
        ovlMarket.liquidate(address(shiva), posId);
        (
            , //uint96 notionalInitial_,
            , //uint96 debtInitial_,
            , //int24 midTick_,
            , //int24 entryTick_,
            , //bool isLong_,
            bool liquidated_,
            , //uint240 oiShares_,
                //uint16 fractionRemaining_
        ) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(liquidated_);
        // rewards balance should be 0 after the position is liquidated
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test that liquidate fails when the caller is not the market
     */
    function test_revert_pol_overlayMarketLiquidateCallback_called_by_non_market() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        vm.startPrank(bob);
        vm.expectRevert();
        shiva.overlayMarketLiquidateCallback(posId);
        assertNotEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test that liquidate fails when the caller is not a valid market
     */
    function test_pol_overlayMarketLiquidateCallback_called_by_impersonator_market() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        vm.startPrank(bob);
        // vm.expectRevert();
        MarketImpersonator impersonator = new MarketImpersonator();
        impersonator.impersonateLiquidation(
            address(shiva), posId, uint96(leverage.mulDown(collateral))
        );
        assertEq(rewardVault.balanceOf(alice), leverage.mulUp(collateral));
    }
}
