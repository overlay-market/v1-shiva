// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardVault} from "src/rewardVault/RewardVault.sol";
import {RewardVaultFactory} from "src/rewardVault/RewardVaultFactory.sol";
import {IStakingRewardsErrors} from "src/rewardVault/berachain/IStakingRewardsErrors.sol";
import {IPOLErrors} from "src/rewardVault/berachain/IPOLErrors.sol";
import {IRewardVault} from "src/rewardVault/IRewardVault.sol";
import {IRewardVaultFactory} from "src/rewardVault/berachain/IRewardVaultFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RewardVaultTest is Test {
    // Tokens
    MockERC20 stakingToken;
    MockERC20 bgt;

    // Contracts
    RewardVaultFactory factory;
    RewardVault rewardVault;

    // Users
    address deployer;
    address alice;
    address bob;

    uint256 constant ONE = 1e18;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        vm.startPrank(deployer);

        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        bgt = new MockERC20("Berachain Governance Token", "BGT", 18);

        // Deploy implementations
        RewardVault rewardVaultImplementation = new RewardVault();
        RewardVaultFactory rewardVaultFactoryImplementation = new RewardVaultFactory();

        // Deploy factory proxy
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(bgt),
            deployer,
            address(rewardVaultImplementation)
        );
        factory = RewardVaultFactory(
            address(new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData))
        );

        // Create a vault
        address vaultAddress = factory.createRewardVault(address(stakingToken));
        rewardVault = RewardVault(vaultAddress);

        vm.stopPrank();

        // Distribute tokens and set approvals
        stakingToken.mint(alice, 1000 * ONE);
        stakingToken.mint(bob, 1000 * ONE);
        bgt.mint(deployer, 10000 * ONE); // Mint BGT for the deployer to use as rewards

        vm.startPrank(alice);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stakingToken.approve(address(rewardVault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Tests that staking correctly updates the user's and vault's balances.
    function test_stake_updates_balance_correctly() public {
        uint256 stakeAmount = 100 * ONE;

        vm.startPrank(alice);

        uint256 initialVaultTokenBalance = stakingToken.balanceOf(address(rewardVault));
        uint256 initialAliceTokenBalance = stakingToken.balanceOf(alice);
        uint256 initialVaultInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        rewardVault.stake(stakeAmount);

        // Check internal vault accounting
        assertEq(
            rewardVault.balanceOf(alice),
            initialVaultInternalBalance + stakeAmount,
            "Vault internal balance for Alice should increase by staked amount"
        );
        assertEq(
            rewardVault.totalSupply(),
            initialVaultTotalSupply + stakeAmount,
            "Vault total supply should increase by staked amount"
        );

        // Check token balances
        assertEq(
            stakingToken.balanceOf(address(rewardVault)),
            initialVaultTokenBalance + stakeAmount,
            "Vault's token balance should increase"
        );
        assertEq(
            stakingToken.balanceOf(alice),
            initialAliceTokenBalance - stakeAmount,
            "Alice's token balance should decrease"
        );

        vm.stopPrank();
    }

    /// @notice Tests that withdrawing correctly updates the user's and vault's balances.
    function test_withdraw_updates_balance_correctly() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 withdrawAmount = 30 * ONE;

        // Alice stakes first
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);

        uint256 initialVaultTokenBalance = stakingToken.balanceOf(address(rewardVault));
        uint256 initialAliceTokenBalance = stakingToken.balanceOf(alice);
        uint256 initialVaultInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        // Alice withdraws a portion
        rewardVault.withdraw(withdrawAmount);

        // Check internal vault accounting
        assertEq(
            rewardVault.balanceOf(alice),
            initialVaultInternalBalance - withdrawAmount,
            "Vault internal balance for Alice should decrease"
        );
        assertEq(
            rewardVault.totalSupply(),
            initialVaultTotalSupply - withdrawAmount,
            "Vault total supply should decrease"
        );

        // Check token balances
        assertEq(
            stakingToken.balanceOf(address(rewardVault)),
            initialVaultTokenBalance - withdrawAmount,
            "Vault's token balance should decrease"
        );
        assertEq(
            stakingToken.balanceOf(alice),
            initialAliceTokenBalance + withdrawAmount,
            "Alice's token balance should increase"
        );

        vm.stopPrank();
    }

    /// @notice Tests that withdrawing more than the staked amount reverts.
    function test_revert_withdraw_insufficient_staked_balance() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 withdrawAmount = stakeAmount + 1;

        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);

        vm.expectRevert(IPOLErrors.InsufficientSelfStake.selector);
        rewardVault.withdraw(withdrawAmount);
        vm.stopPrank();
    }

    /// @notice Tests that withdrawing zero amount reverts.
    function test_revert_withdraw_zero_amount() public {
        vm.startPrank(alice);
        rewardVault.stake(100 * ONE);

        vm.expectRevert(IStakingRewardsErrors.WithdrawAmountIsZero.selector);
        rewardVault.withdraw(0);
        vm.stopPrank();
    }

    /// @notice Tests the full rewards flow for a single staker.
    function test_rewards_flow_single_staker() public {
        uint256 stakeAmount = 100 * ONE;
        uint256 rewardAmount = 500 * ONE;

        // 1. Alice stakes
        vm.startPrank(alice);
        rewardVault.stake(stakeAmount);
        vm.stopPrank();

        // 2. Owner notifies rewards
        vm.startPrank(deployer);
        // The RewardVault holds BGT, so we need to transfer them there first
        bgt.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // Check reward rate
        uint256 rewardsDuration = rewardVault.rewardsDuration();
        assertGt(rewardsDuration, 0, "Rewards duration should be greater than 0");
        assertEq(
            rewardVault.rewardRate(),
            (rewardAmount * PRECISION) / rewardsDuration,
            "Reward rate should be correctly set"
        );

        // 3. Time passes
        uint256 timeToWarp = rewardsDuration / 2;
        vm.warp(block.timestamp + timeToWarp);

        // 4. Check earned rewards
        vm.startPrank(alice);
        uint256 earned = rewardVault.earned(alice);
        // Should be close to half the rewards, accounting for small time differences
        assertApproxEqAbs(earned, rewardAmount / 2, 1e16, "Earned amount is incorrect");

        // 5. Alice claims rewards
        uint256 initialBgtBalance = bgt.balanceOf(alice);
        uint256 claimed = rewardVault.getReward(alice, alice);
        assertApproxEqAbs(claimed, earned, 1e16, "Claimed amount should equal earned amount");

        // 6. Check final state
        assertEq(bgt.balanceOf(alice), initialBgtBalance + claimed, "Alice BGT balance should increase");
        assertEq(rewardVault.rewards(alice), 0, "Pending rewards should be zero after claim");
        vm.stopPrank();
    }

    /// @notice Tests that rewards are split proportionally between two stakers.
    function test_rewards_flow_two_stakers() public {
        uint256 aliceStake = 100 * ONE;
        uint256 bobStake = 300 * ONE;
        uint256 totalStake = aliceStake + bobStake;
        uint256 rewardAmount = 1000 * ONE;

        // 1. Alice and Bob stake
        vm.prank(alice);
        rewardVault.stake(aliceStake);
        vm.prank(bob);
        rewardVault.stake(bobStake);

        // 2. Owner notifies rewards
        vm.startPrank(deployer);
        bgt.transfer(address(rewardVault), rewardAmount);
        rewardVault.notifyRewardAmount(bytes(""), rewardAmount);
        vm.stopPrank();

        // 3. Time passes (full duration)
        uint256 rewardsDuration = rewardVault.rewardsDuration();
        vm.warp(block.timestamp + rewardsDuration);

        // 4. Check earned amounts
        uint256 aliceEarned = rewardVault.earned(alice);
        uint256 bobEarned = rewardVault.earned(bob);
        uint256 totalEarned = aliceEarned + bobEarned;

        uint256 totalRewardWithPrecision = rewardAmount * PRECISION;

        // Total earned should be approx the total reward
        assertApproxEqAbs(totalEarned, rewardAmount, 1e16, "Total earned should equal total reward");
        
        // Alice should have earned her proportional share (100 / 400 = 25%)
        assertApproxEqAbs(
            aliceEarned,
            (rewardAmount * aliceStake) / totalStake,
            1e16,
            "Alice's reward share is incorrect"
        );

        // Bob should have earned his proportional share (300 / 400 = 75%)
        assertApproxEqAbs(
            bobEarned,
            (rewardAmount * bobStake) / totalStake,
            1e16,
            "Bob's reward share is incorrect"
        );
    }

    /// @notice Tests that delegate staking correctly updates all relevant balances.
    function test_delegate_stake_updates_balances() public {
        uint256 delegateStakeAmount = 200 * ONE;

        vm.startPrank(bob); // Bob will delegate stake for Alice

        uint256 initialBobTokenBalance = stakingToken.balanceOf(bob);
        uint256 initialAliceInternalBalance = rewardVault.balanceOf(alice);
        uint256 initialVaultTotalSupply = rewardVault.totalSupply();

        // Bob stakes for Alice
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Check internal vault accounting for Alice
        assertEq(
            rewardVault.balanceOf(alice),
            initialAliceInternalBalance + delegateStakeAmount,
            "Alice's internal balance should increase"
        );
        // Check delegate-specific accounting
        assertEq(
            rewardVault.getDelegateStake(alice, bob),
            delegateStakeAmount,
            "Bob's delegate stake for Alice is incorrect"
        );
        assertEq(
            rewardVault.getTotalDelegateStaked(alice),
            delegateStakeAmount,
            "Alice's total delegate stake is incorrect"
        );
        assertEq(rewardVault.totalSupply(), initialVaultTotalSupply + delegateStakeAmount, "Total supply should increase");

        // Check token balances
        assertEq(stakingToken.balanceOf(bob), initialBobTokenBalance - delegateStakeAmount, "Bob's token balance should decrease");
        
        vm.stopPrank();
    }

    /// @notice Tests that a delegate can withdraw the stake they delegated.
    function test_delegate_withdraw_updates_balances() public {
        uint256 delegateStakeAmount = 200 * ONE;
        uint256 delegateWithdrawAmount = 50 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Now Bob withdraws a portion of his delegated stake
        vm.startPrank(bob);
        uint256 initialBobTokenBalance = stakingToken.balanceOf(bob);
        uint256 initialAliceInternalBalance = rewardVault.balanceOf(alice);
        
        rewardVault.delegateWithdraw(alice, delegateWithdrawAmount);

        // Check balances after withdrawal
        assertEq(rewardVault.balanceOf(alice), initialAliceInternalBalance - delegateWithdrawAmount, "Alice's internal balance should decrease");
        assertEq(rewardVault.getDelegateStake(alice, bob), delegateStakeAmount - delegateWithdrawAmount, "Bob's remaining delegate stake incorrect");
        assertEq(stakingToken.balanceOf(bob), initialBobTokenBalance + delegateWithdrawAmount, "Bob's token balance should increase");
        vm.stopPrank();
    }

    /// @notice Tests that a delegate cannot withdraw more than they have staked for an account.
    function test_revert_delegate_withdraw_insufficient_delegate_stake() public {
        uint256 delegateStakeAmount = 200 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        vm.startPrank(bob);
        vm.expectRevert(IPOLErrors.InsufficientDelegateStake.selector);
        rewardVault.delegateWithdraw(alice, delegateStakeAmount + 1);
        vm.stopPrank();
    }

    /// @notice Tests that a user cannot withdraw funds that were staked by a delegate.
    function test_revert_withdraw_by_user_with_only_delegated_stake() public {
        uint256 delegateStakeAmount = 200 * ONE;

        // Bob stakes for Alice
        vm.prank(bob);
        rewardVault.delegateStake(alice, delegateStakeAmount);

        // Alice tries to withdraw the funds Bob staked for her
        vm.startPrank(alice);
        // This should fail because her self-staked balance is 0.
        vm.expectRevert(IPOLErrors.InsufficientSelfStake.selector);
        rewardVault.withdraw(delegateStakeAmount);
        vm.stopPrank();
    }
} 