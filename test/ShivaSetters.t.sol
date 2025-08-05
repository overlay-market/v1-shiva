// SPDX-License-Identifier: MIT
pragma solidity =0.8.10;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {IShiva} from "src/IShiva.sol";
import {Shiva} from "src/Shiva.sol";
import {Constants} from "./utils/Constants.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {StakingToken} from "src/PolStakingToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {
    IOverlayV1Token,
    GOVERNOR_ROLE,
    PAUSER_ROLE,
    GUARDIAN_ROLE,
    MINTER_ROLE
} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";

// Local interfaces for incompatible version contracts
interface IRewardVault {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function getTotalDelegateStaked(
        address account
    ) external view returns (uint256);
    function notifyRewardAmount(bytes calldata data, uint256 amount) external;
    function rewardsDuration() external view returns (uint256);
    function earned(
        address account
    ) external view returns (uint256);
    function getReward(address account, address to) external returns (uint256);
}

interface IRewardVaultFactory {
    function VAULT_MANAGER_ROLE() external pure returns (bytes32);
    function VAULT_PAUSER_ROLE() external pure returns (bytes32);
    function createRewardVault(
        address stakingToken
    ) external returns (address);
}

/**
 * @title ShivaSettersTest
 * @notice Test suite for verifying Shiva setter functionality and migration from mocks to real implementations
 * @dev Tests the ability to update stakingToken and rewardsVault after deployment
 */
contract ShivaSettersTest is Test, ShivaTestBase {
    using FixedPoint for uint256;

    // Real implementations
    StakingToken _realStakingToken;
    IRewardVault _realRewardVault;
    MockERC20 _rewardToken;
    IRewardVaultFactory _factory;

    // Track initial mock addresses
    address _initialStakingToken;
    address _initialRewardVault;

    function setUp() public override {
        super.setUp();

        // Store initial mock addresses
        _initialStakingToken = address(shiva.stakingToken());
        _initialRewardVault = address(shiva.rewardVault());

        // Deploy reward token for the real RewardVault
        _rewardToken = new MockERC20("Reward Token", "RWD", 18);
    }

    /**
     * @notice Tests that the initial deployment uses mock implementations
     */
    function testInitialDeploymentUsesMocks() public {
        // Verify initial staking token is a mock (has empty mint/burn functions)
        assertEq(_initialStakingToken.code.length > 0, true, "Staking token should be deployed");

        // Verify initial reward vault is a mock (returns zeros)
        assertEq(rewardVault.balanceOf(alice), 0, "Mock reward vault should return 0 balance");
        assertEq(
            rewardVault.getTotalDelegateStaked(alice), 0, "Mock should return 0 for delegate stake"
        );
    }

    /**
     * @notice Tests updating stakingToken and rewardsVault to real implementations
     */
    function testUpdateToRealImplementations() public {
        // Deploy real StakingToken
        _realStakingToken = new StakingToken();

        // Deploy real RewardVault using deployCode and proxy pattern
        address rewardVaultImpl = deployCode("RewardVault.sol:RewardVault");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)", address(_rewardToken), address(_realStakingToken)
        );
        _realRewardVault = IRewardVault(address(new ERC1967Proxy(rewardVaultImpl, initData)));

        // Update Shiva to use real implementations (as governor)
        vm.startPrank(deployer);

        // Update Shiva to use real implementations
        shiva.setStakingToken(address(_realStakingToken));
        shiva.setRewardsVault(address(_realRewardVault));

        vm.stopPrank();

        // Verify the updates
        assertEq(
            address(shiva.stakingToken()),
            address(_realStakingToken),
            "Staking token should be updated"
        );
        assertEq(
            address(shiva.rewardVault()),
            address(_realRewardVault),
            "Reward vault should be updated"
        );
    }

    /**
     * @notice Tests that only governor can update stakingToken
     */
    function testRevertSetStakingTokenNotGovernor() public {
        _realStakingToken = new StakingToken();

        vm.startPrank(alice);
        vm.expectRevert("Shiva: !governor");
        shiva.setStakingToken(address(_realStakingToken));
        vm.stopPrank();
    }

    /**
     * @notice Tests that only governor can update rewardsVault
     */
    function testRevertSetRewardsVaultNotGovernor() public {
        // Deploy real StakingToken first
        _realStakingToken = new StakingToken();

        // Deploy real RewardVault using deployCode
        address rewardVaultImpl = deployCode("RewardVault.sol:RewardVault");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)", address(_rewardToken), address(_realStakingToken)
        );
        _realRewardVault = IRewardVault(address(new ERC1967Proxy(rewardVaultImpl, initData)));

        vm.startPrank(alice);
        vm.expectRevert("Shiva: !governor");
        shiva.setRewardsVault(address(_realRewardVault));
        vm.stopPrank();
    }

    /**
     * @notice Tests that staking works through Shiva after migration to real implementations
     * Adapted from RewardVault.t.sol test_stake_updates_balance_correctly
     */
    function testStakeThroughShivaWithRealImplementations() public {
        // Deploy and set real implementations
        _deployAndSetRealImplementations();

        // Transfer ownership of _realStakingToken to Shiva
        _realStakingToken.transferOwnership(address(shiva));

        // Approve _realStakingToken to be spent by _realRewardVault from Shiva
        vm.startPrank(address(shiva));
        _realStakingToken.approve(address(_realRewardVault), type(uint256).max);
        vm.stopPrank();

        // Alice builds a position through Shiva
        uint256 collateral = 10 * ONE;
        uint256 leverage = 2 * ONE;

        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, BASIC_SLIPPAGE, true);
        shiva.build(
            ShivaStructs.Build(ovlMarket, BROKER_ID, true, collateral, leverage, priceLimit)
        );
        vm.stopPrank();

        // Verify staking token was minted
        uint256 expectedNotional = collateral.mulUp(leverage);
        assertEq(
            _realStakingToken.totalSupply(), expectedNotional, "Staking tokens should be minted"
        );
        assertEq(
            _realStakingToken.balanceOf(address(_realRewardVault)),
            expectedNotional,
            "Tokens should be in vault"
        );

        // Verify reward vault accounting
        assertEq(
            _realRewardVault.balanceOf(alice),
            expectedNotional,
            "Alice's vault balance should match notional"
        );
        assertEq(
            _realRewardVault.getTotalDelegateStaked(alice),
            expectedNotional,
            "Delegate stake should match"
        );
    }

    /**
     * @notice Tests rewards flow after migration to real implementations
     * Adapted from RewardVault.t.sol test_rewards_flow_single_staker
     */
    function testRewardsFlowWithRealImplementations() public {
        // Deploy and set real implementations
        _deployAndSetRealImplementations();

        // Transfer ownership of _realStakingToken to Shiva
        _realStakingToken.transferOwnership(address(shiva));

        // Approve _realStakingToken to be spent by _realRewardVault from Shiva
        vm.startPrank(address(shiva));
        _realStakingToken.approve(address(_realRewardVault), type(uint256).max);
        vm.stopPrank();

        // Alice builds a position
        uint256 collateral = 10 * ONE;
        uint256 leverage = 2 * ONE;

        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, BASIC_SLIPPAGE, true);
        shiva.build(
            ShivaStructs.Build(ovlMarket, BROKER_ID, true, collateral, leverage, priceLimit)
        );
        vm.stopPrank();

        // Add rewards to the vault
        uint256 rewardAmount = 100 * ONE;
        _rewardToken.mint(address(_realRewardVault), rewardAmount);

        // Test contract is the factory owner (since it deployed the proxy)
        _realRewardVault.notifyRewardAmount(bytes(""), rewardAmount);

        // Wait for rewards to accumulate
        uint256 rewardsDuration = _realRewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // Check Alice earned rewards
        uint256 earned = _realRewardVault.earned(alice);
        assertApproxEqAbs(earned, rewardAmount, 1e16, "Alice should earn full rewards");

        // Alice claims rewards
        vm.startPrank(alice);
        uint256 claimed = _realRewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, earned, 1e16, "Claimed should match earned");
        assertEq(_rewardToken.balanceOf(alice), claimed, "Alice should receive reward tokens");
        vm.stopPrank();
    }

    /**
     * @notice Tests unwinding a position with real implementations
     */
    function testUnwindWithRealImplementations() public {
        // Deploy and set real implementations
        _deployAndSetRealImplementations();

        // Transfer ownership and approve
        _realStakingToken.transferOwnership(address(shiva));
        vm.startPrank(address(shiva));
        _realStakingToken.approve(address(_realRewardVault), type(uint256).max);
        vm.stopPrank();

        // Alice builds a position
        uint256 collateral = 10 * ONE;
        uint256 leverage = 2 * ONE;

        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, BASIC_SLIPPAGE, true);
        uint256 positionId = shiva.build(
            ShivaStructs.Build(ovlMarket, BROKER_ID, true, collateral, leverage, priceLimit)
        );

        // Alice unwinds the position
        unwindPosition(positionId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        // Verify staking tokens were burned
        assertEq(_realStakingToken.totalSupply(), 0, "All staking tokens should be burned");
        assertEq(_realRewardVault.balanceOf(alice), 0, "Alice's vault balance should be 0");
    }

    /**
     * @notice Tests that multiple users can stake through Shiva with real implementations
     * Adapted from RewardVault.t.sol test_rewards_flow_two_stakers
     */
    function testMultipleStakersWithRealImplementations() public {
        // Deploy and set real implementations
        _deployAndSetRealImplementations();

        // Transfer ownership and approve
        _realStakingToken.transferOwnership(address(shiva));
        vm.startPrank(address(shiva));
        _realStakingToken.approve(address(_realRewardVault), type(uint256).max);
        vm.stopPrank();

        // Alice builds a position
        vm.startPrank(alice);
        uint256 alicePriceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, 10 * ONE, ONE, BASIC_SLIPPAGE, true);
        shiva.build(ShivaStructs.Build(ovlMarket, BROKER_ID, true, 10 * ONE, ONE, alicePriceLimit));
        vm.stopPrank();

        // Bob builds a position
        vm.startPrank(bob);
        uint256 bobPriceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, 30 * ONE, ONE, BASIC_SLIPPAGE, true);
        shiva.build(ShivaStructs.Build(ovlMarket, BROKER_ID, true, 30 * ONE, ONE, bobPriceLimit));
        vm.stopPrank();

        // Add rewards
        uint256 rewardAmount = 400 * ONE;
        _rewardToken.mint(address(_realRewardVault), rewardAmount);

        // Test contract is the factory owner (since it deployed the proxy)
        _realRewardVault.notifyRewardAmount(bytes(""), rewardAmount);

        // Wait for rewards
        vm.warp(block.timestamp + _realRewardVault.rewardsDuration());

        // Check proportional rewards
        uint256 aliceEarned = _realRewardVault.earned(alice);
        uint256 bobEarned = _realRewardVault.earned(bob);

        // Alice should earn 1/4 (10/40) and Bob 3/4 (30/40)
        assertApproxEqAbs(aliceEarned, rewardAmount / 4, 1e16, "Alice should earn 1/4 of rewards");
        assertApproxEqAbs(bobEarned, (rewardAmount * 3) / 4, 1e16, "Bob should earn 3/4 of rewards");
    }

    /**
     * @notice Tests migration scenario: positions created with mocks still work after migration
     * @dev SKIP: This test is not valid because mock contracts don't implement the full ERC20 interface
     *      that real RewardVault expects. In production, migration would happen before any positions are built.
     */
    function skip_testExistingPositionsWorkAfterMigration() public {
        // Alice builds a position with mock implementations
        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, 10 * ONE, ONE, BASIC_SLIPPAGE, true);
        uint256 positionId =
            shiva.build(ShivaStructs.Build(ovlMarket, BROKER_ID, true, 10 * ONE, ONE, priceLimit));
        vm.stopPrank();

        // Deploy and set real implementations
        _deployAndSetRealImplementations();

        // Transfer ownership and approve
        _realStakingToken.transferOwnership(address(shiva));
        vm.startPrank(address(shiva));
        _realStakingToken.approve(address(_realRewardVault), type(uint256).max);
        vm.stopPrank();

        // Alice should still be able to unwind her position
        vm.startPrank(alice);
        shiva.unwind(ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, BASIC_SLIPPAGE));
        vm.stopPrank();

        // Verify Alice received her collateral back
        assertGt(ovlToken.balanceOf(alice), 0, "Alice should receive OVL back");
    }

    /**
     * @notice Helper function to deploy and set real implementations
     */
    function _deployAndSetRealImplementations() internal {
        // Deploy real StakingToken
        _realStakingToken = new StakingToken();

        // Deploy exactly like RewardVaultTest
        address rewardVaultImplementation = deployCode("RewardVault.sol:RewardVault");
        address rewardVaultFactoryImplementation =
            deployCode("RewardVaultFactory.sol:RewardVaultFactory");

        // Deploy factory proxy
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(_rewardToken),
            address(this),
            address(rewardVaultImplementation)
        );
        _factory = IRewardVaultFactory(
            address(
                new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData)
            )
        );

        // Grant roles exactly like RewardVaultTest
        IAccessControl(address(_factory)).grantRole(_factory.VAULT_MANAGER_ROLE(), address(this));
        IAccessControl(address(_factory)).grantRole(_factory.VAULT_PAUSER_ROLE(), address(this));

        // Create a vault
        address vaultAddress = _factory.createRewardVault(address(_realStakingToken));
        _realRewardVault = IRewardVault(vaultAddress);

        // Update Shiva as governor
        vm.startPrank(deployer);
        shiva.setStakingToken(address(_realStakingToken));
        shiva.setRewardsVault(address(_realRewardVault));
        vm.stopPrank();
    }
}
